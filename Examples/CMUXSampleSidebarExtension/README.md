# CMUX Sample Sidebar Extension

This package is the minimal sample sidebar extension contract for CMUX.

It demonstrates:

- A `CMUXSidebarExtension` implementation.
- A SwiftUI sidebar view that renders a `CMUXSidebarSnapshot`.
- The extension manifest values expected by the host.

The current CMUX host discovers installed ExtensionKit app extensions with extension point `com.manaflow.cmux.sidebar` and hosts scene `sidebar`. This package is intentionally package-shaped so the contract is visible in the workspace and covered by tests. A follow-up installable `.appex` sample should wrap `CMUXSampleSidebarView` in an ExtensionKit target.
