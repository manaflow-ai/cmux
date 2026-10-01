# Acpmux web bridge v1

`AcpmuxWebBridgeProtocol.swift` defines the small versioned host contract between Swift and the React pane. Swift starts or finds acpmux, then returns its authenticated loopback WebSocket endpoint, a per-launch bearer token, and the selected session id. React connects directly to acpmux, sends `_acpmux/attach {eventStream: true}`, pages with `beforeSeq`, folds event records into rows, and sends ACP and `_acpmux/*` actions. Swift remains the WKWebView host and owns native-only actions; acpmux owns session state and business logic.

The React preview at `webviews/src/agent-session/acpmux-preview` uses recordings of the same acpmux event stream with a mock host handshake. The daemon WebSocket listener supports query-token authentication, so Safari/WKWebView can connect without setting an Authorization header.
