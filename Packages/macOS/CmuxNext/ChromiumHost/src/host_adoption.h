// The Chromium Host outlives a crash of cmux (task p01-process-150 of
// plans/cmux-next/chrome-parity/p01-process.md, behind the feature
// chromiumHostSurvivesAppCrash, which cmux passes as --survives-app-crash).
//
// Chrome keeps no browser process alive for a new one, but its pieces exist:
// a child outlives a crashed browser only while its pipe is open, and a
// Mojo invitation is accepted only from a peer the platform vouches for
// (mojo/public/cpp/platform/named_platform_channel.h; on macOS the peer's
// audit token and code signature, as base/mac/mach_port_rendezvous.cc checks
// a child's). The host does the same over a Unix socket:
//
//   - The control channel ends with EOF or an I/O error and no kOpShutdown
//     came first: the host keeps its pages, listens on SocketPath(root cache)
//     (mode 0600) and arms a kGraceSeconds deadline. A shutdown op, a bad
//     message or a start that never initialized ends the host as before.
//   - A connection whose peer is not this user's process signed by this
//     host's team (audit token, code signature: browser_host_main.mm) is
//     closed before it is read.
//   - The first frame is kOpAdopt (an Offer). The host answers kOpAdoptReply:
//     kAdopted, and the connection becomes the control channel (the new
//     peer's HELLO comes next, HostContext::Reattach); kVersionMismatch, and
//     the host closes every page so Chromium writes its profile, then ends,
//     and cmux restores each tab from its history record with a new host;
//     kMalformed, and the connection is closed.
//   - No adoption in kGraceSeconds: the host ends as at a quit.
//
// Needs no CEF or AppKit: scripts/cmux-next/tests/chromium-host-wire.test.sh
// compiles it with host_adoption_test.cpp on Linux too. ChromiumHostAdoption.swift
// is the cmux side; both tests check the same golden offer.
#pragma once

#include <sys/types.h>

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <optional>
#include <string>

#include "chromium_host_control.h"

namespace cmux_host::adoption {

// The spawn argument that turns survival on (ChromiumHostConfiguration).
inline constexpr char kSwitch[] = "survives-app-crash";
inline constexpr char kSocketName[] = "chromium-host.sock";
// How long an orphaned host keeps its pages for a relaunched cmux.
inline constexpr int kGraceSeconds = 30;
// macOS's sun_path less its NUL: a longer path goes to ShortSocketPath.
inline constexpr size_t kMaxSocketPathBytes = 103;

// The two frames of an adoption connection, before its control stream.
inline constexpr uint16_t kOpAdopt = 0x8020;
inline constexpr uint16_t kOpAdoptReply = 0x8021;

// The Chromium framework binary a host runs, by its file: an update that
// replaces the framework gives it another inode, so a host started before
// the update is never adopted by the cmux after it (its next helper would be
// the new framework's).
struct FrameworkIdentity {
  int64_t device = 0;
  int64_t inode = 0;
  int64_t size = 0;
  int64_t mtime = 0;  // seconds
  friend bool operator==(const FrameworkIdentity&, const FrameworkIdentity&) = default;
};

// stat(2) of `binary`; nullopt when it cannot be read.
std::optional<FrameworkIdentity> IdentityOf(const std::string& binary);

// kOpAdopt, field order: str wire id (kWireID), str shim ABI id (kShimAbiID),
// i32 the lowest fork API cmux runs with (kMinForkAPI), i64 framework device,
// i64 inode, i64 size, i64 mtime, i32 cmux's pid.
struct Offer {
  std::string wire_id;
  std::string abi_id;
  int32_t min_fork_api = 0;
  FrameworkIdentity framework;
  int32_t app_pid = 0;
};

control::Message EncodeOffer(const Offer& offer);
// Nullopt for any other op, a reply, descriptors or a field that is not the
// layout above.
std::optional<Offer> ReadOffer(const control::Message& message);

// What the host is: compared with an offer.
struct HostVersions {
  std::string wire_id;
  std::string abi_id;
  int32_t fork_api = 0;
  FrameworkIdentity framework;
};

enum class Verdict : int32_t {
  kAdopted = 0,
  kVersionMismatch = 1,
  kMalformed = 2,
};

// kAdopted only when the wire, the shim ABI and the framework are the host's
// and the host's fork API is at least the offer's.
Verdict Judge(const std::optional<Offer>& offer, const HostVersions& host);

// kOpAdoptReply, field order: i32 verdict, i32 host pid, i32 host fork API,
// i32 the first browser id and i32 the first DevTools id the new peer may
// mint (HostContext::mint_floor), str the host's resize fence inbox name (""
// none).
struct Reply {
  Verdict verdict = Verdict::kMalformed;
  int32_t host_pid = 0;
  int32_t fork_api = 0;
  int32_t mint_browser = 0;
  int32_t mint_devtools = 0;
  std::string resize_fence;
};

control::Message EncodeReply(const Reply& reply);
std::optional<Reply> ReadReply(const control::Message& message);

// `<root_cache>/chromium-host.sock`, or ShortSocketPath when that is over
// kMaxSocketPathBytes (a tagged build's long bundle id). Empty for an empty
// root cache.
std::string SocketPath(const std::string& root_cache, uid_t uid);
// `/tmp/cmux-chromium-host-<uid>/<fnv1a64(root_cache), 16 hex digits>.sock`,
// in a directory of mode 0700 that Listen makes (AcpmuxEnvironment.shortAlias's
// rule, so a long path keeps one socket per data folder).
std::string ShortSocketPath(const std::string& root_cache, uid_t uid);
// ShortSocketPath's directory.
std::string ShortSocketDirectory(uid_t uid);
uint64_t Fnv1a64(const std::string& text);

// A listening socket at `path`: close-on-exec, non-blocking, the file mode
// 0600. A stale socket file there goes first; any other file there, or a
// short path's directory that is not this user's with mode 0700, fails.
// -1 with errno on failure.
int Listen(const std::string& path);
// Removes the socket file Listen made, when `path` still is a socket.
void Unlisten(const std::string& path);

// The orphan's listener: one thread, com.cmuxterm.chromium-host.adoption
// (user-initiated: a relaunched cmux waits for its answer;
// plans/cmux-next/threading-model.md), that blocks in poll(2) on the socket
// until a connection or the grace deadline, never on the host's UI thread.
// For each connection: the peer check first (nothing is read from a peer it
// refuses), then the offer within `read_limit`, the verdict and the reply. A
// malformed offer or a refused peer closes that connection and the wait goes
// on; an adoption or a mismatch ends it, as does the deadline. The socket file
// goes when the wait ends. `done` runs once, on the listener thread.
class Listener {
 public:
  // The trusted peer's pid, or nullopt to refuse it (browser_host_main.mm: the
  // peer's uid, audit token and code signature, host_peer_mac.mm).
  using CheckPeer = std::function<std::optional<pid_t>(int fd)>;
  struct Outcome {
    enum class Kind { kAdopted, kVersionMismatch, kExpired, kFailed };
    Kind kind = Kind::kFailed;
    int fd = -1;        // kAdopted: the new control channel, blocking, close-on-exec
    pid_t app_pid = 0;  // kAdopted: the adopting cmux
    int error = 0;      // kFailed: errno of the listen
  };
  using Done = std::function<void(Outcome)>;
  struct Options {
    std::string path;
    HostVersions versions;
    Reply reply;  // the host's fields; the verdict is set per connection
    std::chrono::milliseconds grace{std::chrono::seconds(kGraceSeconds)};
    std::chrono::milliseconds read_limit{std::chrono::seconds(2)};
    CheckPeer check_peer;
    Done done;
  };

  // Starts the thread; it owns everything it needs and ends by itself.
  static void Start(Options options);
  // The thread's work, on the calling thread (tests).
  static void Run(Options options);
};

// Whether an ended control channel leaves an orphan (true) or ends the host.
// `survives`: the spawn's kSwitch; `running`: CefInitialize returned and the
// host is not quitting (no kOpShutdown, no bad message).
bool KeepsPages(control::End end, bool survives, bool running);

}  // namespace cmux_host::adoption
