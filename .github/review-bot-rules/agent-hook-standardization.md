# Agent Hook Standardization

Apply this rule to cmux-owned agent hook installation, command generation, hook config writers, hook docs, and hook tests.

## Fail

- A new or changed agent hook integration hand-writes per-event shell command strings instead of routing through `AgentHookDef`, `hookCommandString`, `feedHookCommandString`, and the shared hook config builders.
- A diff adds an agent-specific hook command generator, dispatcher marker, installed config shape, timeout rule, or environment rule without a behavior reason tied to that agent and coverage proving the shared path is insufficient.
- A diff hardcodes app bundle paths, socket paths, or release channel names in hook generator code, tests, or docs outside the shared pinned hook dispatch path.
- A diff changes pinned hook behavior without preserving owned-hook markers, install-time CLI/socket pinning, fallback to `command -v cmux`, disable-env handling, and legacy cmux-owned hook pruning.
- A diff adds or changes Feed bridge events without preserving the longer Feed timeout and source/event routing through `cmux hooks feed --source <agent> --event <event>`.

## Pass

- A new agent is added as metadata in `AgentHookDef` and uses the existing shared JSON/YAML/plugin writer for its format.
- Agent-specific config writing is limited to an agent-native file format or plugin API while command dispatch still goes through the shared helpers.
- Pinned dispatch is used for agents that do not preserve `CMUX_*` hook environment, with tests showing why normal `CMUX_SURFACE_ID`, `CMUX_SOCKET_PATH`, and `CMUX_BUNDLED_CLI_PATH` interpolation cannot work.
- Existing hook complexity is moved into shared helpers without weakening legacy uninstall or reinstall cleanup.

## Report

When this rule fails, name the file and line, identify the duplicated or agent-specific hook path, and suggest the smallest source-of-truth fix in the shared hook definition, command generator, or config writer.
