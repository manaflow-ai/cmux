# CMUX Extension Host Support

`CMUXExtensionHostSupport` is the host-side package for loading and driving CMUX sidebar extensions.

This package contains:

- a SwiftUI `EXHostViewController` bridge for rendering the extension scene
- a small browser presenter used by CMUX's sidebar extension picker

The exported surface is intentionally sidebar-only: `CmuxExtensionKit` defines the manifest, snapshot, and action contract, while the CMUX app owns discovery, permission grants, snapshot filtering, and action dispatch policy.
