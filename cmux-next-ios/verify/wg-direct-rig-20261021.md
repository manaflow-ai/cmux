# WireGuard link-up and path on the two-mini rig after #23829 (2026-10-21)

Question: after #23829 (WireGuard offers every usable IPv4 interface address and resends an
unanswered handshake through TURN at 0.25/0.75/1.75/3.75 s), does a relayed link still take
5 s, and does the link reach Direct when a direct path exists?

Answer:

- **The 5 s stall is gone.** Every fresh WireGuard link came up in 70 to 138 ms (one TURN over
  TLS link took 812 ms). Before #23829 every relayed link took 5.1 to 6.1 s, with a boringtun
  `HANDSHAKE(REKEY_TIMEOUT)` just before "link up". No REKEY line falls between a session's
  offer and its link up now.
- **The link still never goes Direct on this rig, and the reason is the rig, not the link
  code.** The hidden rig Mac's `cmux-mobile-host` gets `No route to host (os error 65)` for
  every UDP send to the phone's LAN address. A shell process on the same Mac reaches the same
  address and port. That is macOS Local Network privacy refusing the hidden app, which no one
  can allow (see Path below).

## What ran

| Part | What |
| --- | --- |
| Mac | Fleet build `c3275a4e272fcfb2c773e693` (aws-m4pro-4), tag `cmux-mobile-wg23829-afa6d468`, `--production` (Debug app, production sign-in). Commit `afa6d468874` is feat-cmux-next `e8d058f26ff` (contains #23829, `e1ea6763daac`) merged with #22870's branch. Hidden on mini-cmux11s (`open -g -j -n`); settings only through `open --env`. The hostd ran through `CMUX_NEXT_MOBILE_HOST_BIN`, a wrapper that sets `CMUX_MOBILE_LOG=info,cmux_mobile_link=debug,cmux_mobile_link::dial::wireguard=trace,cmux_mobile_host=debug` and execs the bundled `cmux-mobile-host` (the app passes no other environment to hostd) |
| Phone | TestFlight-config simulator app of `fadca699cc1` (`afa6d468874` plus the iOS compile fix below), made like the acceptance run: `testflight-build.sh --unsigned --no-asc --config TestFlight` with `CMUX_MOBILE_SIMULATOR_APP`, Xcode 26.6, on mini-cmux8s. One headless iPhone 17 Pro (iOS 26.5), deleted afterwards |
| Link | Simulator (mini-cmux8s, LAN 172.20.21.191) to Mac (mini-cmux11s, LAN 172.20.21.195), production signaling and TURN. No local socket or loopback |
| Driver | `verify/e2e/wg_connects.py`: signs in once, then relaunches the app for each connect and reads the rig Mac's link line on Settings > Devices |
| Relay switch | The TestFlight build has no Relay only toggle (DEBUG only). The rig's equivalent is `SIMCTL_CHILD_CMUX_MOBILE_DEV_BLOCK_UDP=1`, which the FFI reads in any build: no plain UDP and no TURN over UDP, so WireGuard uses TURN over TLS on 443 |

The first iOS build failed: #23829 left `TransportKind` ambiguous in
`LiveCoordinator+Links.swift` (`CmuxMobileModel.TransportKind` and
`CmuxMobileTransport.TransportKind` are both visible), which only an iOS compile sees. The PR
that adds this note fixes it and adds a CI job that runs the package's tests on an iOS simulator.

## Numbers

Timings come from the Mac's `link up` and `first channel` lines (`timings=`, from the offer).
"Phone" is the line on Settings > Devices.

| Connect | Mac path | Phone | video_lane | link_ready | first_channel |
| --- | --- | --- | --- | --- | --- |
| default 1 | Turn | Connected · WireGuard relay (TURN) · 14 ms | 75.0 ms | 75.0 ms | 77.3 ms |
| default 2 | Turn | Connected · WireGuard relay (TURN) · 16 ms | 70.0 ms | 70.0 ms | 71.2 ms |
| default 3 | Turn | Connected · WireGuard relay (TURN) · 16 ms | 80.5 ms | 80.6 ms | 83.7 ms |
| TLS 1 | TurnTls | Connected · WireGuard relay (TURN over TLS) · 14 ms | 74.5 ms | 74.5 ms | 77.4 ms |
| TLS 2 | TurnTls | Connected · WireGuard relay (TURN over TLS) · 14 ms | 78.4 ms | 78.5 ms | 80.6 ms |
| TLS 3 | TurnTls | Connected · WireGuard relay (TURN over TLS) · 17 ms | 812.1 ms | 812.1 ms | 812.2 ms |

Five earlier default connects in the same session (driver iterations) read 137.8, 74.6, 82.5,
75.1 and 86.5 ms link_ready, all `path=Turn`. In the default runs the line stayed on relay for
the 20 s watched after Connected; no "link path changed" followed the first.

Before #23829 (acceptance run 8 and the laptop and phone logs): link_ready 5.1 to 6.1 s with
video_lane about the same, a `HANDSHAKE(REKEY_TIMEOUT)` before "link up", `path=Turn`.

The `HANDSHAKE(KEEPALIVE + REKEY_TIMEOUT)` and `REKEY_TIMEOUT` lines that still appear come
about 12 s after the driver kills the previous app process: they are that dead session timing
out ("link down ... keepalive timed out"), not the new link.

## Path: why not Direct

From the Mac's debug log, every connect:

```
TRACE cmux_mobile_link::dial::wireguard: UDP send failed error=No route to host (os error 65) target=172.20.21.191:58300
DEBUG cmux_mobile_link::dial::wireguard: peer confirmed our datagrams reach it direct=Some(Route { carrier: Udp, addr: 104.30.x.x:31372 })
INFO  cmux_mobile_host::host: link up ... kind=WireGuard path=Turn ... link_ready=75.0ms
```

- The phone offered its LAN address (172.20.21.191) and the Mac tried it first. The send failed
  at once with EHOSTUNREACH. The route that confirmed is the phone's TURN relayed address
  (104.30.x.x).
- From an ssh shell on the same Mac, `nc -u 172.20.21.191 40123` reached a listener on
  mini-cmux8s, over en0. The network and routing are fine. Only the GUI app's child process is
  refused, which is how macOS Local Network privacy fails a send. The hidden rig app has never
  been granted Local Network access, and its prompt cannot be answered on a rig.
- No phone datagram on the LAN route reached the Mac either (no "the peer receives us on another
  route", no "WireGuard route changed"). The TestFlight build does not log the phone side at
  trace level, so the phone's own LAN sends were not observed.
- Tailscale is not tried: the app runs hostd with `CMUX_MOBILE_EXCLUDE_CGNAT=1`, so 100.64/10
  addresses are never offered.

So on this rig WireGuard cannot go Direct whatever the link code does. Direct needs a Mac app
that has Local Network access (a person allows it once, or an MDM profile), or a rig where the
Mac's hostd is not a GUI app's child. That was not done here.

Evidence (git-ignored, on the laptop that ran this):
`~/cmux-mobile-builds/20261021-wg-rig-23829/evidence/` holds `default/`, `blockudp/` and
`direct/` (`run.log`, `results.json`, `shots/`) and the Mac's `cmux-mobile-host.log`.
