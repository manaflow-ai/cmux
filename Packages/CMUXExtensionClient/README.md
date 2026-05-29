# CMUX Extension Client

`CMUXExtensionClient` is the host-side package for loading and driving CMUX sidebar extensions.

This first slice contains:

- manifest validation through `CmuxExtensionKit`
- a registry for available sidebar extensions
- a session actor that fetches snapshots and dispatches sidebar actions

The package is ready for an ExtensionKit-backed adapter, but this branch keeps the first verified surface focused on the API and host lifecycle. Future work should add the real `EXHostViewController` bridge and third-party extension discovery.
