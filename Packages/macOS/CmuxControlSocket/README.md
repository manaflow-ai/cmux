# CmuxControlSocket

Client-side wire types the cmux CLI shares for the control socket: startup
waiting (`SocketStartupWaiter`, `SocketStartupWaitTimeout`), stream error
classification (`SocketStreamErrorKind`, `EventStreamFailure`), the
per-command client capability envelope, the browser download wait budget, and
the set of polling methods a server may rate-limit (`SocketPollingMethods`).

The listener, dispatch and coordinators of the legacy app's socket server were
deleted with that app; cmux-next serves the socket from
`Packages/macOS/CmuxNext/Sources/CmuxNextControl`.
