import CmuxAgentChat
import Foundation

extension ChatArtifactTemporaryFileWriter {
    static func classifyLocalFailure(_ error: any Error) -> ChatArtifactError {
        if let artifactError = error as? ChatArtifactError {
            return artifactError
        }
        if let posixError = error as? POSIXError {
            return classifyLocalFailure(posixCode: posixError.code)
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain,
           let code = POSIXErrorCode(rawValue: Int32(nsError.code)) {
            return classifyLocalFailure(posixCode: code)
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying !== nsError {
            return classifyLocalFailure(underlying)
        }
        if let cocoaError = error as? CocoaError,
           cocoaError.code == .fileWriteOutOfSpace {
            return .localStorageFull
        }
        return .localStorageUnavailable
    }

    private static func classifyLocalFailure(posixCode: POSIXErrorCode) -> ChatArtifactError {
        switch posixCode {
        case .ENOSPC, .EDQUOT:
            return .localStorageFull
        default:
            return .localStorageUnavailable
        }
    }
}

actor ChatArtifactStreamValidation {
    private var validator: ChatArtifactChunkValidator

    init(expectedSize: Int64?) {
        validator = ChatArtifactChunkValidator(expectedSize: expectedSize)
    }

    func receive(_ chunk: ChatArtifactChunk) throws {
        try validator.receive(chunk)
    }

    func finish() throws {
        try validator.finish()
    }
}
