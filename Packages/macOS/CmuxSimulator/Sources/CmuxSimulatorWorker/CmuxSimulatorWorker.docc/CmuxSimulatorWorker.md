# Isolated Simulator Worker

This target owns private Simulator frameworks, framebuffer capture, input injection, accessibility bridges, privacy mutation, and camera injection. It resolves Simulator framebuffer GPU synchronization inside the child and publishes completed packed-BGRA slots through a permission-restricted, versioned shared-memory ring.

`Process` owns worker lifetime and dependency wiring. `Framebuffer`, `Input`, `Accessibility`, `Privacy`, `Camera`, and `WebInspector` own their private runtime objects. `WebInspector` talks directly to the selected Simulator's Unix socket with Foundation property lists, contains target-based routing, and releases every sender when its page, device, socket, or worker closes. Bundled helper and injector sources remain under `Resources` with their upstream notices.
