# CmuxSudoBroker

CmuxSudoBroker owns cmux's macOS sudo-approval spool, request lifecycle, and
bounded privileged execution contract. The package has no AppKit dependency;
the app supplies presentation while the bundled CLI supplies request and runner
entrypoints.

Tests use a temporary application-support directory and injected clock, PAM,
runner, and process-lifecycle seams. They never invoke sudo or Touch ID.
