# CMUX Extension Kit

`CmuxExtensionKit` is the zero-dependency public contract for CMUX sidebar extensions.

Version 1 only supports sidebar extensions. The API exposes a stable workspace snapshot and a small action channel:

- read the current sidebar snapshot
- select a workspace
- close a workspace
- ask CMUX to open a URL

The snapshot intentionally starts small: workspace identity, title, detail text, paths, git branch, unread state, listening ports, and pull request URLs. It does not expose terminal buffers, shell history, environment variables, secrets, or arbitrary filesystem access.

Host-side lifecycle, discovery, and display belong in `Packages/CMUXExtensionClient`.
