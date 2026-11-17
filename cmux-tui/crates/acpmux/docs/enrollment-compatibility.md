# Enrollment checks usability before build identity

Adding an SSH machine must reach its peer handshake even when the caller and
remote daemon have different CPU architectures, operating systems, or builds.
The install step cannot infer wire compatibility from a commit hash. A running
foreign-platform daemon stays running, including when another binary is already
installed beside it. The daemon step still checks its listener and token; the
peer step reports actual protocol or capability failures.

When no binary is available, enrollment downloads the standalone acpmux artifact
for the remote target from the published channel. It shares the self-update
channel parser and checksum contract, holds the remote update lock, checks the
download before replacement, and renames a staged file on the same filesystem.
A failed download or checksum leaves the installed binary and its backup intact.
An app-owned executable is repaired through its app, never replaced by standalone
acpmux. Unsupported platforms retain the target-specific repair instruction.

The original failure coupled enrollment repair to installing the caller's exact
build; a healthy server therefore failed before the protocol could negotiate.
Detectors: `cross_platform_enroll_keeps_a_running_daemon_of_another_build`,
`daemon_skew_on_another_platform_keeps_the_running_daemon`,
`cross_platform_install_bootstraps_a_missing_binary_from_the_checked_channel`,
and `bootstrap_download_checks_bytes_before_atomic_install`.
