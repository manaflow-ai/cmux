import Foundation

struct ApplicationWindowDescriptor: Identifiable, Equatable, Sendable {
    var id: UInt32 { windowID }

    let windowID: UInt32
    let processID: Int32
    let owner: String
    let title: String
    let width: Double
    let height: Double
}
