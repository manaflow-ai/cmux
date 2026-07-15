import CmuxMobileRPC

enum DiffTreeRowKind: Sendable, Equatable {
    case directory(isExpanded: Bool)
    case file(MobileDiffFileStatus)
}
