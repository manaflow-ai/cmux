# Wake on intent (a paused Cloud machine starts waking before the first key; idle 30 s, it pauses again)

- Section: Cloud
- Mac sends: page `cloudMachine.wakeHint {v, id, signal}` (focus, terminal); the app asks `cloud_handler_wake_*` (cmux-cloud-handlers `wake_hint`), then a script-originated `cloud.machine.start` or `cloud.machine.pause`. Default on, `cloud.wakeOnIntent` is the kill switch (cmux#55749).
- Phone: the app becoming active (unlock) with a Cloud machine's chats in front forwards `unlock` (`CloudWakeOnIntent`); the same rules decide (cmux-mobile-link-ffi `cloud_wake.rs`, one ledger per process); start and pause with the phone's own account, origin `script`, in the machine's Cloud team; each sent prompt (`AcpmuxHub.submit`) is the input
- State: partial
- Notes: cmux#55941. Hidden and default off on the phone: DEBUG/Demo builds only, `-cmuxMobile.dev.wakeOnIntent YES` (`DeveloperOptions.wakeOnIntent`), no Settings row. Calls only the account's own Cloud service, as the Machines page does: no new trust policy (SECURITY.md). Rust tests: `cloud_wake::tests`. Not yet run on a phone or simulator.
