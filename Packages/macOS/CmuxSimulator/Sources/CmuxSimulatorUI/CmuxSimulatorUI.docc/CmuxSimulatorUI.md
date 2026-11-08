# ``CmuxSimulatorUI`` ownership

This target owns the in-process SwiftUI and AppKit host for Simulator panes.

- `Coordinator` owns pane lifecycle, device selection, public Simulator controls, and worker recovery.
- `Input` converts AppKit events into ordered, normalized HID messages.
- `Chrome` reads DeviceKit metadata and computes device bezel geometry.
- `Process` supervises recording and log subprocesses while decoding output off the main actor.
- `Views` renders the pane and its native tool controls.
- The Web Inspector tools keep only bounded response previews; the process-safe chunk stream remains available to native clients that need complete output.
- `Debug` contains debug-build-only renderer diagnostics.

Private Simulator framework calls and framebuffer capture remain isolated in `CmuxSimulatorWorker`; UI code communicates with them only through `CmuxSimulator` messages. The host maps packed frame slots read-only, validates their publication versions, and deep-copies pixels off-main into immutable Core Graphics images. Core Animation never receives worker-owned or shared storage.
