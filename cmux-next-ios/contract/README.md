# The phone's connection contract

One fixture, read by both sides:
`rust/crates/cmux-mobile-link-ffi/tests/fixtures/connection_contract.json`.

| Reader | What it checks | Runs in |
|---|---|---|
| `rust/crates/cmux-mobile-link-ffi/tests/connection_contract.rs` | `mac_reachability_resolve`/`_action`/`_span` give each case's answer; every `LinkEvent` and `MediaState` variant is listed and sent by a scenario (exhaustive `match`: a new variant does not compile); each scenario's events keep the order `LinkEvent` documents; each protocol version equals the fixture and its old-peer tests exist | rust-workspaces (any `cmux-next-ios/rust/**` change), ios-link-ffi-linux |
| `CmuxMobileKit/Tests/CmuxMobileLinkFFILinuxTests/ConnectionContractTests.swift` | the same cases through the real Swift binding; every variant name, through an exhaustive `switch` | ios-link-ffi-linux |
| `CmuxMobileKit/Tests/CmuxMobileLiveTests/ConnectionContractScenarioTests.swift` | each scenario's Rust events, mapped as FFIMacLink's StateObserver and LinkController.adopt map them, drive `LinkMachine` to the phase, effects and media the fixture says | cmux-next-ios-kit, swift-linux-packages (ios-kit), FlowSuite `reconnect-after-drop` |
| `CmuxMobileKit/Tests/CmuxMobileModelTests/ConnectionContractCopyTests.swift` | every kind Rust resolves is a `MacReachability` the Mac's view can show, in the fixture's words | swift-linux-packages (ios-kit) |

A Rust change to a resolution, an event, an event's order or a protocol version fails the Rust test. The fix updates the fixture, and the updated fixture fails the Swift suites until iOS handles the change. Rust cannot move ahead of iOS without a red check.

Why the contract sits at the protocol and the events, not the FFI ABI: the uniffi Swift and the Rust library ship in one app binary, and `build-linux-ffi.sh` fails when bindgen's output differs from the checked-in `CmuxMobileLinkFFI.swift`. The skew that can reach a person is behavioural (an event iOS maps wrong, an order it does not expect) or between a phone and a Mac of different versions.

## Version skew, both ways

| Version | Value | The older peer gets | Guards |
|---|---|---|---|
| `WG_VERSION` | 3 | relay frames, reach and trickle beside version 3 | `a_version_2_peer_keeps_reach_and_trickle_beside_version_3`, `wireguard_with_an_older_peer_confirms_by_its_datagrams` |
| `WG_REACH_VERSION` | 2 | the three-second relay rule | `an_older_peer_keeps_the_three_second_relay_rule`, `an_older_phone_against_a_new_mac_keeps_the_three_second_relay_rule` |
| `MULTIPATH_VERSION` | 3 | no second socket, no metered message | `metered_messages_old_and_new` |
| `AD_VERSION` | 1 | newer ads skipped; a missing version reads as 1 | `lockstep_newer_ad_version_is_skipped_by_this_browser`, `lockstep_unknown_keys_and_missing_version_read_as_v1` |
| `HUB_VERSION` | 1 | the version-0 signaling subset | `lockstep_hello_hub_version_both_ways`, `lockstep_old_phone_against_new_hub`, `lockstep_new_phone_against_old_and_new_hub` |
| park | – | an older Mac refuses: keep the link and probe it | `an_older_mac_refuses_the_park`, scenario "background a moment, an older Mac refuses the park" |
| media lane | – | browser video stays on the channel | `wireguard_with_an_older_mac_stays_on_the_channel`, `wireguard_with_an_older_phone_stays_on_the_channel` |

A version bump that leaves the fixture behind fails `every_protocol_version_matches_and_names_its_old_peer_tests`. So does renaming or deleting a guard.

## What could regress next, and what catches it

| Behaviour | Could regress by | Caught by |
|---|---|---|
| connect | Rust sends `Connected` without `Connecting`, or a new first event | scenario `connect`; order check |
| drop + reconnect | silent retry count, backoff, a dead link's late events counted | scenarios `drop, a silent retry…`, `a dead link's late events…`; LinkRecoveryTests |
| attach during reconnect | an attach given up while the redial is in flight (row 1) | scenarios `a surface opens…` (both); AttachWaitsForTheLinkTests |
| Mac asleep / offline | presence "offline" closes a live link; an open retries forever | scenario `Mac asleep…`; reachability cases `Mac asleep…`; ConnectivityMatrixTests |
| Mac silent, listed online | probe failure closes instead of keeping a standby | scenario `Mac silent while listed online…`; reachability `listed online, the dial got no answer` |
| network change | a live link redialed instead of roamed (row 11), a dial left on a dead path | scenario `network change…`; LiveTests `networkChangeRoamsWithoutRedialing`, `changesDuringARoamWaitForItAndRoamOnceMore`; NetworkPathFilterTests |
| background / foreground | park not asked, a short stay redialed, a long one closing first | scenarios `background…` (four); LinkParkTests |
| media | a `MediaState` iOS does not map, media left on after a drop | scenarios `browser media…`, `a dead link's late events…` |
| status words | Rust resolves a kind the view cannot show, or the words change | ConnectionContractCopyTests |
| the whole flow on devices | anything above, end to end | FlowSuite `reconnect-after-drop` (pair_e2e), now selected by any change to the link, FFI, host, protocol or the Swift link sources |

Gaps this suite closes (2026-11-27):
- Nothing tied `LinkEvent` or `MediaState` variants to iOS.
- No shared fixture tied Rust's event order to `LinkMachine`.
- Rust reachability rules and the Swift words were tested apart.
- No check tied version bumps to their old-peer tests.
- `reconnect-after-drop` ran only for `cmux-remote` changes.

## Changing the contract

Change the Rust code, update the fixture until `cargo test -p cmux-mobile-link-ffi --test connection_contract` passes, then make the Swift suites pass in the same PR. A new step kind or event needs a line in `ConnectionContractScenarioTests.apply`/`observe`, mirroring the app's own mapping.

## App-level API: one method list, served by the Mac

The link contract above versions the pipe. What rides it (daemon commands, acpmux methods,
link services) is versioned here, so a phone and a Mac from different days keep working
(Leo: "well clearly we need to be able to support the multiple versions as it goes").

- **One list.** `cmux-next-ios/rust/crates/cmux-mobile-api/phone-api.json` names every
  method a phone may call or read: `link/<service>`, `daemon/<command or event>`,
  `acpmux/<method>`, each with JSON Schemas cut from `cmux-tui/spec/sdk-schema.json` and
  `acpmux-protocol.json`. It is generated, never edited.
- **Served by the Mac.** hostd's `api` service (capability `api-describe-v1`):
  `{"op":"list"}` (what this Mac serves now, plus a digest), `{"op":"describe","method":M}`
  (schemas and every type they reach), `{"op":"llms"}` (as text). A Mac without it replies
  `unknown_service`; the phone falls back to `version` capabilities.
- **Capabilities, not versions.** The phone asks `cmux_mobile_api::Discovery::supports`
  (`Yes`, `No`, or `Unknown` on an older Mac) and `supports_field` for a field marked
  `x-capability`.
- **Strict requests.** hostd checks every phone daemon line against its command's schema.
  A field the schema does not name is logged; a phone that opens `daemon` with
  `"strict": true` gets `unknown_field` instead. No default changed for older phones.
- **Tolerant readers.** Result and event schemas are read open: a reader skips fields and
  events it does not know.
- **CI.** `cargo test -p cmux-mobile-host --test phone_api_contract` fails when the list
  is stale, when a method changed without a rule in `phone-api.compat.json` (the same
  break rules as `cmux-api-compat` uses for the daemon and acpmux), when a phone-allowed
  daemon command has no schema, when the Swift app names an acpmux method not in
  `api.rs` `PHONE_ACPMUX_METHODS`, or when hostd serves an unlisted service.

To change a method: change its IR, run
`CMUX_UPDATE_PHONE_API=1 cargo test -p cmux-mobile-host --test phone_api_contract`, and
when the test names a break, add a revision with one rule per break to
`phone-api.compat.json` first.
