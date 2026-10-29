// Whether the browser host the provider link dialed is code signed as this
// cmux (host_provider_link.h ProviderLinkPeerSignedAsCmux,
// p01-process.md risk 6). The peer is named by its audit
// token (LOCAL_PEERTOKEN), never by pid, so a process that reused the
// browser host's pid never passes:
//   - this build has a Team ID: the peer satisfies `anchor apple generic and
//     certificate leaf[subject.OU] = "<Team ID>"` (the browser host side does
//     the same check, cmux_link::caller::verify);
//   - this build has no Team ID (unsigned or ad hoc): the peer's executable,
//     read by its token (proc_pidpath_audittoken), lies in this binary's own
//     app bundle;
//   - this build's signing information cannot be read: refused.
// Runs on the link's reader thread, once per dial. macOS only; the link's
// Linux tests pass their own check.

#include "host_provider_link.h"

#if defined(__APPLE__)

#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <libproc.h>
#include <mach-o/dyld.h>
#include <mach/message.h>
#include <sys/socket.h>
#include <sys/un.h>

#include <climits>
#include <cstdlib>

namespace cmux_host {

namespace {

// Releases a Core Foundation object on scope exit.
class CFHeld {
 public:
  explicit CFHeld(CFTypeRef ref = nullptr) : ref_(ref) {}
  ~CFHeld() {
    if (ref_) CFRelease(ref_);
  }
  CFHeld(const CFHeld&) = delete;
  CFHeld& operator=(const CFHeld&) = delete;
  CFTypeRef get() const { return ref_; }
  CFTypeRef* out() { return &ref_; }

 private:
  CFTypeRef ref_;
};

enum class OwnSigning { kTeam, kUnsigned, kUnknown };

// This process's Team ID, ten upper-case letters or digits, when it has one.
OwnSigning OwnTeam(std::string* team) {
  SecCodeRef self = nullptr;
  if (SecCodeCopySelf(kSecCSDefaultFlags, &self) != errSecSuccess || !self) return OwnSigning::kUnknown;
  CFHeld held_self(self);
  SecStaticCodeRef static_code = nullptr;
  if (SecCodeCopyStaticCode(self, kSecCSDefaultFlags, &static_code) != errSecSuccess || !static_code) {
    return OwnSigning::kUnknown;
  }
  CFHeld held_static(static_code);
  CFDictionaryRef info = nullptr;
  if (SecCodeCopySigningInformation(static_code, kSecCSSigningInformation, &info) != errSecSuccess || !info) {
    return OwnSigning::kUnknown;
  }
  CFHeld held_info(info);
  const void* value = CFDictionaryGetValue(info, kSecCodeInfoTeamIdentifier);
  if (!value) return OwnSigning::kUnsigned;
  if (CFGetTypeID(value) != CFStringGetTypeID()) return OwnSigning::kUnknown;
  char buffer[64] = {};
  if (!CFStringGetCString(static_cast<CFStringRef>(value), buffer, sizeof buffer, kCFStringEncodingUTF8)) {
    return OwnSigning::kUnknown;
  }
  const std::string id(buffer);
  if (id.size() != 10) return OwnSigning::kUnknown;
  for (const char c : id) {
    if (!((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))) return OwnSigning::kUnknown;
  }
  *team = id;
  return OwnSigning::kTeam;
}

bool PeerToken(int fd, audit_token_t* token) {
  socklen_t length = sizeof *token;
  return ::getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, token, &length) == 0 && length == sizeof *token;
}

// The running code `token` names satisfies `team`'s requirement.
bool SignedByTeam(const audit_token_t& token, const std::string& team) {
  CFHeld data(CFDataCreate(nullptr, reinterpret_cast<const UInt8*>(&token), sizeof token));
  if (!data.get()) return false;
  const void* keys[] = {kSecGuestAttributeAudit};
  const void* values[] = {data.get()};
  CFHeld attributes(CFDictionaryCreate(nullptr, keys, values, 1, &kCFTypeDictionaryKeyCallBacks,
                                       &kCFTypeDictionaryValueCallBacks));
  if (!attributes.get()) return false;
  SecCodeRef guest = nullptr;
  if (SecCodeCopyGuestWithAttributes(nullptr, static_cast<CFDictionaryRef>(attributes.get()), kSecCSDefaultFlags,
                                     &guest) != errSecSuccess ||
      !guest) {
    return false;
  }
  CFHeld held_guest(guest);
  const std::string text = "anchor apple generic and certificate leaf[subject.OU] = \"" + team + "\"";
  CFHeld string(CFStringCreateWithCString(nullptr, text.c_str(), kCFStringEncodingUTF8));
  if (!string.get()) return false;
  SecRequirementRef requirement = nullptr;
  if (SecRequirementCreateWithString(static_cast<CFStringRef>(string.get()), kSecCSDefaultFlags, &requirement) !=
          errSecSuccess ||
      !requirement) {
    return false;
  }
  CFHeld held_requirement(requirement);
  return SecCodeCheckValidity(guest, kSecCSDefaultFlags, requirement) == errSecSuccess;
}

// The real path of `path`; empty when it cannot be resolved.
std::string RealPath(const char* path) {
  char resolved[PATH_MAX] = {};
  return ::realpath(path, resolved) ? std::string(resolved) : std::string();
}

// The outermost `*.app` directory that holds `path` (with its trailing
// slash); empty when none does.
std::string OuterAppBundle(const std::string& path) {
  for (size_t found = path.find(".app/"); found != std::string::npos; found = path.find(".app/", found + 5)) {
    // A component named `<name>.app`, not a bare `.app`.
    const size_t start = path.rfind('/', found);
    if (start != std::string::npos && found > start + 1) return path.substr(0, found + 5);
  }
  return std::string();
}

// The executable `token` names lies in this binary's own app bundle.
bool InThisBundle(audit_token_t token) {
  char peer[PROC_PIDPATHINFO_MAXSIZE] = {};
  if (proc_pidpath_audittoken(&token, peer, sizeof peer) <= 0) return false;
  char own[PATH_MAX] = {};
  uint32_t size = sizeof own;
  if (_NSGetExecutablePath(own, &size) != 0) return false;
  const std::string own_bundle = OuterAppBundle(RealPath(own));
  return !own_bundle.empty() && OuterAppBundle(RealPath(peer)) == own_bundle;
}

}  // namespace

bool ProviderLinkPeerSignedAsCmux(int fd) {
  audit_token_t token = {};
  if (!PeerToken(fd, &token)) return false;
  std::string team;
  switch (OwnTeam(&team)) {
    case OwnSigning::kTeam:
      return SignedByTeam(token, team);
    case OwnSigning::kUnsigned:
      return InThisBundle(token);
    case OwnSigning::kUnknown:
      return false;
  }
  return false;
}

}  // namespace cmux_host

#endif  // defined(__APPLE__)
