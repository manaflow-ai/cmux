# Bound Bun agent updates

Bun updates keep the observed package directory, bin directory and global
configuration selection in their argv. They preserve the detected package name,
including a fork. Another shell's Bun defaults cannot select the installation.

Discovery reads the owner's `BUN_INSTALL`, `BUN_INSTALL_GLOBAL_DIR`,
`BUN_INSTALL_BIN` and global `.bunfig.toml` paths. An absolute `XDG_CONFIG_HOME`
selects that global config instead of the home file. Environment directory
overrides win; `~/` paths expand under the owner home. Malformed, relative or
oversized configuration is refused. These rules follow
[Bun's configuration contract](https://bun.com/docs/runtime/bunfig).

On Unix, the fixed plan uses `/usr/bin/env` with explicit package/bin overrides.
It either sets the observed `XDG_CONFIG_HOME` or removes that variable with
`-u`, so execution cannot pick a different global config from its environment.
The manager's absolute executable is captured before execution. No shell or
temporary configuration file interprets the plan. Windows and Brew bindings
remain unsupported by the visible owner-job planner.

Cached commands without this binding are removed from health results before
Settings or other consumers can receive them. Requested updates, automatic
updates and the private plan/prepare RPCs share the validator. Batch identity
includes both directories, so separate installations are not deduplicated.
Filesystem preparation rechecks the selected executable, install channel,
package, paths and manager without running version, sign-in or registry probes.

The discovery-only login variables are stored for the owner; they do not expand
the default environment passed to agent children. Only the selected Bun update
gets the fixed overrides. Public inventory still omits paths, commands and
plans. The existing verified-Frontend admission, owner/session checks, durable
idempotency and receipt redaction remain the execution boundary; caller JSON
cannot supply argv, environment or actor authority. No App or remote execution
grant is added.

The response schema remains `{cli, argv}`. The owner accepts at most nine
arguments and 16 KiB; older owners refuse the longer plan rather than dropping
its binding. Older cache readers can execute the self-contained argv without
understanding new metadata fields. No persistent schema or cache format changes.
