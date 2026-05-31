# CMUX Extension Client

`CMUXExtensionClient` is the host-side package for loading and driving CMUX sidebar extensions.

This package contains:

- manifest validation through `CmuxExtensionKit`
- a registry for available sidebar extensions
- a session actor that fetches snapshots and dispatches sidebar actions
- third-party sidebar extension discovery for `com.manaflow.cmux.sidebar`
- a SwiftUI `EXHostViewController` bridge for rendering the extension scene

The exported surface is intentionally sidebar-only: `CmuxExtensionKit` defines the manifest, snapshot, and action contract, while this package owns host lifecycle, discovery, registry lookup, session dispatch, and the ExtensionKit host view.
