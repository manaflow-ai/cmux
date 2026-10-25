// The app's memory consumer registrations (plans/cmux-next/chrome-parity/p07-memory.md, task 077).
//
// Chrome registers each memory consumer where it is built (base/memory_coordinator/memory_consumer.h:
// the consumer owns its RAII `MemoryConsumerRegistration`). cmux's composition root is AppServices, so
// the wiring of every package's consumers lives in this one file and AppServices.swift calls
// `registerMemoryConsumers()` once. Each package adds one line or one small function here, kept in
// package name order, so parallel changes add lines and do not edit the same ones. It is its own type,
// not an AppServices extension, so these lines never grow the AppServices god type.

/// Registers every package's memory consumers with the app's memory coordinator.
struct AppMemoryConsumers {
    /// The services whose subsystems own the consumers.
    let services: AppServices

    /// AppServices' init calls this once, after the services the consumers belong to are built. Each
    /// consumer's owner keeps its registration token; nothing here stores one.
    func registerMemoryConsumers() {
        _ = services.memoryCoordinator  // follows pressure from launch, before any consumer registers
        // One line per package, sorted by package name, for example:
        // registerTabs()  // CmuxNextTabs
    }
}
