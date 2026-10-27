// Who may adopt an orphaned Chromium Host (host_adoption.h, task
// p01-process-150): a process of this user whose code, named by the audit
// token the kernel gave the socket (never its pid, which can be reused),
// satisfies the designated requirement of the app this host belongs to and is
// signed by this host's own team. As base/mac/mach_port_rendezvous.cc checks
// a peer's code signature by audit token before it hands over a port.
// An unsigned or ad-hoc signed host has no team: it trusts no peer, so a
// development build without a team never adopts.
#include "host_peer.h"

#import <Foundation/Foundation.h>
#include <Security/Security.h>
#include <sys/socket.h>
#include <sys/ucred.h>
#include <sys/un.h>
#include <unistd.h>

#include <cctype>

#ifndef LOCAL_PEERTOKEN
#define LOCAL_PEERTOKEN 0x006  // sys/un.h
#endif

namespace cmux_host {

namespace {

// The team of the running code, "" when it has none (ad-hoc, unsigned).
std::string OwnTeam() {
  SecCodeRef self = nullptr;
  if (SecCodeCopySelf(kSecCSDefaultFlags, &self) != errSecSuccess || !self) return std::string();
  SecStaticCodeRef code = nullptr;
  const OSStatus copied = SecCodeCopyStaticCode(self, kSecCSDefaultFlags, &code);
  CFRelease(self);
  if (copied != errSecSuccess || !code) return std::string();
  CFDictionaryRef info = nullptr;
  const OSStatus read = SecCodeCopySigningInformation(code, kSecCSSigningInformation, &info);
  CFRelease(code);
  if (read != errSecSuccess || !info) return std::string();
  std::string team;
  if (CFStringRef value = static_cast<CFStringRef>(CFDictionaryGetValue(info, kSecCodeInfoTeamIdentifier));
      value && CFGetTypeID(value) == CFStringGetTypeID()) {
    const char* text = [(__bridge NSString*)value UTF8String];
    if (text) team = text;
  }
  CFRelease(info);
  return team;
}

bool PlainTeam(const std::string& team) {
  if (team.empty()) return false;
  for (char c : team) {
    if (!isalnum(static_cast<unsigned char>(c))) return false;
  }
  return true;
}

// The designated requirement of the app bundle at `path`.
SecRequirementRef AppRequirement(const std::string& path) {
  NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path.c_str()]];
  SecStaticCodeRef app = nullptr;
  if (SecStaticCodeCreateWithPath((__bridge CFURLRef)url, kSecCSDefaultFlags, &app) != errSecSuccess || !app) {
    return nullptr;
  }
  SecRequirementRef requirement = nullptr;
  const OSStatus status = SecCodeCopyDesignatedRequirement(app, kSecCSDefaultFlags, &requirement);
  CFRelease(app);
  return status == errSecSuccess ? requirement : nullptr;
}

}  // namespace

std::optional<pid_t> TrustedPeer(int fd, const std::string& app_bundle) {
  @autoreleasepool {
    xucred credentials{};
    socklen_t size = sizeof credentials;
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &credentials, &size) != 0 || credentials.cr_version != XUCRED_VERSION ||
        credentials.cr_uid != geteuid()) {
      return std::nullopt;
    }
    pid_t pid = 0;
    size = sizeof pid;
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) != 0 || pid <= 1) return std::nullopt;
    audit_token_t token{};
    size = sizeof token;
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) != 0) return std::nullopt;
    static const std::string team = OwnTeam();
    if (!PlainTeam(team) || app_bundle.empty()) return std::nullopt;

    NSData* token_data = [NSData dataWithBytes:&token length:sizeof token];
    NSDictionary* attributes = @{(__bridge NSString*)kSecGuestAttributeAudit : token_data};
    SecCodeRef peer = nullptr;
    if (SecCodeCopyGuestWithAttributes(nullptr, (__bridge CFDictionaryRef)attributes, kSecCSDefaultFlags, &peer) !=
            errSecSuccess ||
        !peer) {
      return std::nullopt;
    }
    bool trusted = false;
    SecRequirementRef app = AppRequirement(app_bundle);
    NSString* team_text =
        [NSString stringWithFormat:@"anchor apple generic and certificate leaf[subject.OU] = \"%s\"", team.c_str()];
    SecRequirementRef same_team = nullptr;
    if (app && SecRequirementCreateWithString((__bridge CFStringRef)team_text, kSecCSDefaultFlags, &same_team) ==
                   errSecSuccess) {
      trusted = SecCodeCheckValidity(peer, kSecCSDefaultFlags, app) == errSecSuccess &&
                SecCodeCheckValidity(peer, kSecCSDefaultFlags, same_team) == errSecSuccess;
    }
    if (same_team) CFRelease(same_team);
    if (app) CFRelease(app);
    CFRelease(peer);
    if (!trusted) return std::nullopt;
    return pid;
  }
}

}  // namespace cmux_host
