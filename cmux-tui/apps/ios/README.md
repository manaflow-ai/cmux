# cmux remote for iOS

A phone client for the cmux remote daemon, over Iroh.

It exists to exercise the transport on the network a phone actually has: NAT'd,
changing between cellular and Wi-Fi, and often unable to reach the daemon
directly at all. Those are the conditions the relay path and session resume are
for, and they do not occur on a loopback test.

## What it does

Paste a `cmux://enroll/...` invitation, connect, and get a shell on the machine
that issued it. The status bar shows whether Iroh settled on a direct or relayed
path, and counts session resumes, so a walk out of Wi-Fi range is visible rather
than inferred.

The path picker forces direct-only or relay-only. Automatic is what a user would
run; the constrained modes are there so a failure can be attributed to one path
instead of "the network".

## Architecture

The app implements none of the daemon protocol. Enrollment is a
PSK-authenticated Noise handshake, sessions are mutually authenticated and
resumable, frames carry per-lane sequence numbers with bounded replay, and Iroh
adds path selection and relay fallback underneath. A Swift reimplementation
would be a second set of bugs in exactly the parts that are hardest to test, so
the app links `cmux-remote-mobile`, a C ABI over the same Rust client the TUI
uses.

It also carries no VT parser. The daemon keeps the terminal model and answers
`SnapshotProcessTerminal` with styled runs, so `TerminalScreen` only lays out a
monospaced grid. Wrapping, scroll regions, and character sets stay on the side
that already got them right.

## Build

```bash
brew install xcodegen
cd cmux-tui/apps/ios
xcodegen generate
open CmuxRemote.xcodeproj
```

The Rust archive builds from a pre-build script, so a plain Xcode build is
enough. No Zig toolchain is involved: `cmux-remote-mobile` depends on
`cmux-remote` with `default-features = false`, which leaves out the daemon's
workspace service and with it libghostty-vt.

`CmuxRemote.xcodeproj` is generated and not committed.

## Getting an invitation

On the machine you want to reach:

```bash
cmux-tui daemon invite
```

It prints a `cmux://enroll/...` URI that expires in five minutes and carries the
daemon's public key plus route hints. The key is what the phone pins during the
handshake; the hints only say where to try, so a wrong or stale hint cannot
redirect the session to another host. The daemon asks the machine's owner to
approve the device before the first session completes.
