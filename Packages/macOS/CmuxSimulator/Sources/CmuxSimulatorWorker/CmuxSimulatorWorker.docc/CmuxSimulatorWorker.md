# Isolated Simulator Worker

This target owns private Simulator frameworks, framebuffer transport, input injection, accessibility bridges, privacy mutation, and camera injection. The cmux process exchanges only Codable messages and a remote Core Animation context identifier with this child process.

`Process` owns worker lifetime and dependency wiring. `Framebuffer`, `Input`, `Accessibility`, `Privacy`, `Camera`, and `WebInspector` own their private runtime objects. `WebInspector` talks directly to the selected Simulator's Unix socket with Foundation property lists, contains target-based routing, and releases every sender when its page, device, socket, or worker closes. Bundled helper and injector sources remain under `Resources` with their upstream notices.
