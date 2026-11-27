import AppKit

struct AgentSessionWebHostGeometryState: Equatable {
    let frame: CGRect
    let bounds: CGRect
    let windowNumber: Int?
    let superviewID: ObjectIdentifier?
}
