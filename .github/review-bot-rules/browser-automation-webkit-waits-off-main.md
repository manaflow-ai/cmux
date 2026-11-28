# Browser Automation WebKit Waits Off Main

Apply this rule to cmux browser socket automation commands in `Sources/TerminalController.swift` and `Packages/macOS/CmuxControlSocket/Sources/CmuxControlSocket/Wire/ControlCommandExecutionPolicy.swift`.

## Fail

- A `browser.*` socket command that waits on `WKWebView.evaluateJavaScript`, `callAsyncJavaScript`, `v2RunJavaScript`, `v2RunBrowserJavaScript`, `v2AwaitCallback`, `WKHTTPCookieStore`, screenshot callbacks, or injected page hooks is routed through `.mainActor` or the main `processV2Command` switch instead of the socket-worker policy and worker router.
- A browser command moved to the socket worker still resolves panels, touches AppKit/WebKit UI, mutates browser state dictionaries, or captures UI directly off main actor instead of using the shared main hop helpers such as `v2BrowserWithPanelContext` and `v2MainSync`.
- A new or moved worker-lane browser command is missing `ControlCommandExecutionPolicyTests` coverage that proves it is classified as a socket worker method and not a main actor method.

## Pass

- Direct UI/focus commands that only select, show, or route focus without waiting on WebKit/page callbacks may remain main actor routed.
- Helper functions may stay `@MainActor` when every caller waits from a socket-worker command and performs only the minimum UI hop needed to resolve WebKit/AppKit state.
- Existing main-actor browser automation debt that the PR does not introduce or worsen passes, but new commands should follow the worker-lane pattern.

## Report

When this rule fails, name the exact file, line, and browser command, explain which wait or callback can hang the main actor, and suggest the smallest source-of-truth fix: add the command to `ControlCommandExecutionPolicy.socketWorkerMethods`, route it through the worker browser automation switch, keep WebKit/AppKit access inside explicit main hops, and add policy coverage.
