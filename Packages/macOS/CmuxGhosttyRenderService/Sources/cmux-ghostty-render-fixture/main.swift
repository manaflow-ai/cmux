import CmuxTerminalRenderTransport
import Foundation

let channel = TerminalRenderMessageChannel(readDescriptor: 0, writeDescriptor: 1)
let environment = ProcessInfo.processInfo.environment
let crashAfterInitialize = environment["CMUX_GHOSTTY_RENDER_FIXTURE_CRASH"] == "1"
let crashOnceFile = environment["CMUX_GHOSTTY_RENDER_FIXTURE_CRASH_ONCE_FILE"]
let initializationLog = environment["CMUX_GHOSTTY_RENDER_FIXTURE_INITIALIZATION_LOG"]
let mutationLog = environment["CMUX_GHOSTTY_RENDER_FIXTURE_MUTATION_LOG"]
let resizeReleaseRevision = environment["CMUX_GHOSTTY_RENDER_FIXTURE_RESIZE_RELEASE_REVISION"]
    .flatMap(UInt64.init)
var shouldHoldResizeAcknowledgements = resizeReleaseRevision != nil
var heldResizeAcknowledgements: [TerminalRenderWorkerEvent] = []

func send(_ event: TerminalRenderWorkerEvent) {
    guard let payload = try? TerminalRenderControlCodec.encode(event) else { return }
    try? channel.send(payload)
}

func recordInitializationRevision(_ revision: UInt64) {
    guard let initializationLog else { return }
    let url = URL(fileURLWithPath: initializationLog)
    if !FileManager.default.fileExists(atPath: url.path) {
        _ = FileManager.default.createFile(atPath: url.path, contents: Data())
    }
    guard let handle = try? FileHandle(forWritingTo: url) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: Data("\(revision)\n".utf8))
}

func appendMutationLog(_ line: String) {
    guard let mutationLog else { return }
    let url = URL(fileURLWithPath: mutationLog)
    if !FileManager.default.fileExists(atPath: url.path) {
        _ = FileManager.default.createFile(atPath: url.path, contents: Data())
    }
    guard let handle = try? FileHandle(forWritingTo: url) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: Data("\(line)\n".utf8))
}

@MainActor
func acknowledgeResize(
    id: UUID,
    generation: UInt64,
    width: UInt32,
    height: UInt32
) {
    let event = TerminalRenderWorkerEvent.resizeApplied(
        id: id,
        generation: generation,
        width: width,
        height: height
    )
    if shouldHoldResizeAcknowledgements {
        heldResizeAcknowledgements.append(event)
    } else {
        send(event)
    }
}

while let payload = channel.receive() {
    guard let command = try? TerminalRenderControlCodec.decodeCommand(payload) else {
        send(.failure("decode failed"))
        continue
    }
    switch command {
    case let .initialize(version, generation, _, configuration):
        recordInitializationRevision(configuration.revision)
        send(.initialized(
            protocolVersion: version,
            workerGeneration: generation,
            processIdentifier: ProcessInfo.processInfo.processIdentifier
        ))
        if crashAfterInitialize {
            exit(86)
        }
        if let crashOnceFile,
           !FileManager.default.fileExists(atPath: crashOnceFile) {
            _ = FileManager.default.createFile(atPath: crashOnceFile, contents: Data())
            exit(86)
        }
    case let .createSurface(descriptor):
        send(.surfaceCreated(id: descriptor.id, generation: descriptor.generation))
    case let .resynchronizeSurface(descriptor, nextSequence, _):
        send(.surfaceCreated(id: descriptor.id, generation: descriptor.generation))
        send(.outputApplied(
            id: descriptor.id,
            generation: descriptor.generation,
            nextSequence: nextSequence
        ))
    case let .mutateSurface(id, generation, mutation):
        switch mutation {
        case let .processOutput(sequence, bytes):
            appendMutationLog("output \(sequence) \(bytes.base64EncodedString())")
            send(.outputApplied(
                id: id,
                generation: generation,
                nextSequence: sequence + UInt64(bytes.count)
            ))
        case let .resize(width, height):
            appendMutationLog("resize \(width) \(height)")
            acknowledgeResize(
                id: id,
                generation: generation,
                width: width,
                height: height
            )
        default:
            continue
        }
    case let .destroySurface(id, generation):
        send(.surfaceDestroyed(id: id, generation: generation))
    case let .replaceConfiguration(configuration):
        guard let resizeReleaseRevision,
              configuration.revision >= resizeReleaseRevision else {
            continue
        }
        shouldHoldResizeAcknowledgements = false
        let acknowledgements = heldResizeAcknowledgements
        heldResizeAcknowledgements.removeAll(keepingCapacity: false)
        for acknowledgement in acknowledgements {
            send(acknowledgement)
        }
    case .shutdown:
        exit(0)
    }
}

exit(0)
