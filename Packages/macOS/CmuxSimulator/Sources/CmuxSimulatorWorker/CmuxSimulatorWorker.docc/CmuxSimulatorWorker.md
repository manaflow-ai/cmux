# Isolated Simulator Worker

This target owns private Simulator frameworks, framebuffer capture, input injection, accessibility bridges, privacy mutation, and camera injection. The cmux process exchanges Codable messages plus identifiers for global IOSurfaces whose lifetime is retained independently by the host.

`Process` owns worker lifetime and dependency wiring. `Framebuffer`, `Input`, `Accessibility`, `Privacy`, `Camera`, and `WebInspector` own their private runtime objects. `WebInspector` talks directly to the selected Simulator's Unix socket with Foundation property lists, contains target-based routing, and releases every sender when its page, device, socket, or worker closes. Bundled helper and injector sources remain under `Resources` with their upstream notices.
