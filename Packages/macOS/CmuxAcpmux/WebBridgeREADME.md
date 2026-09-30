# Acpmux web bridge v1

`AcpmuxWebBridgeProtocol.swift` defines the versioned JSON contract between the Swift session model and the React pane. Swift sends `snapshot` values containing row ids and content versions, connection/session state, permissions, queue entries, and the model/mode/effort catalog. React sends action values for prompt, cancel, permission answers, configuration changes, session selection/creation, and older-history paging. Swift remains the only owner of acpmux state and business logic.

The React preview at `webviews/src/agent-session/acpmux-preview` uses the same snapshot and action shapes with a mock bridge and recordings from the acpmux test fixtures.
