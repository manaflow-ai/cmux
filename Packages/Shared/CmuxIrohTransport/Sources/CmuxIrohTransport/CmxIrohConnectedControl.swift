import Foundation

/// The admitted connection and control stream produced by one connect task.
struct CmxIrohConnectedControl: Sendable {
    let connection: any CmxIrohConnection
    let stream: CmxIrohBidirectionalStream
    let initialReceiveBuffer: Data
}
