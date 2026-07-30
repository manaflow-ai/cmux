import Foundation

struct AppKitSignalLabTask: Equatable, Identifiable {
    let id: UUID
    var title: String
    var owner: String
    var status: AppKitSignalLabStatus
    var progress: Double
    var priority: Int
}
