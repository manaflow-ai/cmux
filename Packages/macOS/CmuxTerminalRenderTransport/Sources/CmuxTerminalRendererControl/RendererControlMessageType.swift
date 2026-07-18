internal import CmuxTerminalRenderProtocol

/// Stable wire tags for renderer-control message payloads.
enum RendererControlMessageType: UInt8 {
    case bootstrap = 0x01
    case upsertPresentation = 0x02
    case removePresentation = 0x03
    case semanticScene = 0x04
    case frameRelease = 0x05
    case shutdown = 0x06
    case ready = 0x81
    case needsFullScene = 0x82
    case fatal = 0x83
    case presentationReady = 0x84
    case presentationRemoved = 0x85

    var direction: RendererControlDirection {
        switch self {
        case .bootstrap, .upsertPresentation, .removePresentation,
             .semanticScene, .frameRelease, .shutdown:
            .daemonToWorker
        case .ready, .needsFullScene, .fatal, .presentationReady, .presentationRemoved:
            .workerToDaemon
        }
    }

    var payloadLengthRange: ClosedRange<Int> {
        switch self {
        case .bootstrap:
            48...48
        case .upsertPresentation:
            96...(96 + TerminalRenderFrameProtocol.maximumServiceNameLength
                + TerminalRenderFrameProtocol.capabilityLength
                + RendererControlProtocol.maximumResolvedConfigLength)
        case .removePresentation:
            56...56
        case .semanticScene:
            80...(80 + RendererControlProtocol.maximumSemanticSceneLength)
        case .frameRelease:
            96...96
        case .shutdown:
            8...8
        case .ready:
            24...24
        case .needsFullScene:
            72...72
        case .fatal:
            16...(16 + RendererControlProtocol.maximumDiagnosticLength)
        case .presentationReady:
            104...104
        case .presentationRemoved:
            56...56
        }
    }
}
