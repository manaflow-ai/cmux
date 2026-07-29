#if os(iOS)
import CMUXMobileCore

enum MobileIrohPrivatePathProbePresentation: Equatable {
    case idle
    case testing
    case finished(CmxIrohPrivatePathProbeResult)
}
#endif
