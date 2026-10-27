public enum IrxConnectionError: Error, Sendable {
    case closed(IrxTermination?)
    case admissionTimeout
    case malformedPeerFrame
    case laneRejected(IrxLaneError)
}
