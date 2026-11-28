# Terminal no-link timeout experiment

The self-reattach timeout is off by default pending verification on a real phone.
For a development launch, pass `-experiments.terminalNoLinkTimeout YES` as app
launch arguments (for example, in the Xcode scheme). The session reads the app's
UserDefaults preference when it is created. Remove the launch argument to restore
the default if no persistent value was set; otherwise remove that preference too.

With the experiment enabled, an already attached terminal whose channel ends and
whose Mac link is unavailable shows the existing Retry error after 30 seconds.
The cached screen stays visible. Retry and the existing automatic retry can
recover when the link returns, and successful attachment clears the error.
A first attach still waits for the link without this session-specific timeout.
With the experiment disabled, self-reattach keeps the existing no-link wait.

Before enabling this by default, verify on a real phone: an outage longer than
30 seconds, manual Retry, automatic recovery through two offline retry rounds,
a link returning before the timeout, and first-attach input preserved until the
link returns. Record the build SHA, device and results. Simulator evidence alone
does not enable the default.

The regression detector is `TerminalSelfRecoveryTests` in
`CmuxMobileLiveTests/DaemonTerminalSessionTests.swift`; its parameterized no-link
case exercises both the disabled wait and enabled manual/automatic recovery.
