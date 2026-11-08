# CmuxCloudImagePaste

This macOS package owns the transport-independent Cloud clipboard image model,
safe reader, error taxonomy, and authenticated upload coordinator. The app
injects the leased cmux-tui control sender; the package never opens a network
socket or accepts a caller-selected remote path.

The coordinator accepts only PNG, JPEG, GIF, and WebP signatures and bounds
payloads to 20 MiB. Its upload deadline uses an injected `Clock<Duration>` and
cancels the deadline task when the transfer finishes, is cancelled, or disconnects.

Tests can construct `CloudImagePasteCoordinator(deadline: .seconds(5), clock: testClock)`
and bind a scripted sender. `CloudImagePasteMirrorIntegrationTests` additionally
exercises the real mirror connection and response decoder over a fixture socket.
