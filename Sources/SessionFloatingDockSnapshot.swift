import Foundation

/// Persisted geometry and visibility for one workspace floating Dock.
struct SessionFloatingDockSnapshot: Codable, Sendable {
    var id: UUID
    var title: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var isPresented: Bool
    var configurationSeedIdentity: String? = nil
    var configurationContent: DockControlDefinition? = nil
    var configurationBaseDirectory: String? = nil
}
