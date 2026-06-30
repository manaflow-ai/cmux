#if canImport(UIKit) && DEBUG
import UIKit

@MainActor
protocol MobileZoomStressLineProbeSource: AnyObject {
    var zoomStressLineCount: Int { get }
}

@MainActor
final class MobileZoomStressLineProbeView: UIView {
    weak var lineSource: (any MobileZoomStressLineProbeSource)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityIdentifier = "MobileZoomStressLineProbe"
    }

    @available(*, unavailable, message: "Use init(frame:) for the DEBUG stress probe.")
    required init?(coder: NSCoder) {
        return nil
    }

    override var accessibilityValue: String? {
        get { "line=\(lineSource?.zoomStressLineCount ?? 0)" }
        set {}
    }
}
#endif
