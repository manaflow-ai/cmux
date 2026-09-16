# CodeRouter ownership

The Rust `cmux-cli` owns the cmux model-plane commands:

- `cmux coderouter status`, which combines `auth.status` with the selected team's Claude upstream list.
- `cmux coderouter machines`, which reports Cloud machine usage through `coderouter.machines`.
- `cmux coderouter claude ...`, which manages team-owned Claude upstream credentials through the `coderouter.claude_upstream.*` socket methods.
- `cmux coderouter agent ...`, which forwards to the shared `cmux vm agent` path.
- `cmux coderouter capabilities --json`, which is a versioned command catalog and explicitly separates personal `account`, team `upstream`, and Cloud `machine` resources.

`cmux cr` always invokes the separately distributed CodeRouter CLI. Unknown `coderouter` verbs do the same. The passthrough preserves argv and stdio with `exec`, and removes `CMUX_*`/`CMUXD_*` variables so a standalone CLI cannot accidentally consume cmux socket or control-plane state. The managed install directory (`$CODEROUTER_INSTALL/bin`, then `$HOME/.coderouter/bin`) is searched after `PATH`.

`--json` preserves the legacy command payload shape. `--output json` uses the Rust CLI envelope. `--explain` adds transport and resource metadata. A future command should add a new resource name or socket method explicitly, rather than treating a personal CodeRouter account as a team upstream or a Cloud machine.

Known migration gap: native passthrough currently reports the documented install command when the standalone binary is absent. Interactive bootstrap installation remains in the Swift compatibility adapter until the root dispatcher removes that adapter; moving the bootstrap flow is safe but should be a separate, tested change because it downloads and executes an installer.
