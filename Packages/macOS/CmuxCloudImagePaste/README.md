# CmuxCloudImagePaste

This macOS package owns the transport-independent Cloud clipboard image model,
safe reader, error taxonomy, and authenticated upload coordinator. The app
injects the leased cmux-tui control sender; the package never opens a network
socket or accepts a caller-selected remote path.

The coordinator accepts only PNG, JPEG, GIF, and WebP signatures and bounds
payloads to 20 MiB. Tests can inject `CloudImagePasteCoordinator.DeadlineSleep`
to advance or fail a deadline without using the filesystem or a live daemon.
