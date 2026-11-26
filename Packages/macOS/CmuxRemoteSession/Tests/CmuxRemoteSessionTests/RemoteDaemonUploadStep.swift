enum RemoteDaemonUploadStep: Equatable {
    case createDirectory
    case upload
    case finalize
    case cleanup
    case unknown
}
