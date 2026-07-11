#if os(iOS)
import UIKit

final class TranscriptPinnedBottomMaskView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityIdentifier = "transcript.chrome.bottom-mask"
        updateColors()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateColors()
    }

    private func updateColors() {
        guard let gradient = layer as? CAGradientLayer else { return }
        let background = UIColor.systemBackground
        gradient.colors = [
            background.withAlphaComponent(0).cgColor,
            background.withAlphaComponent(0.72).cgColor,
            background.withAlphaComponent(0.98).cgColor,
        ]
        gradient.locations = [0, 0.58, 1]
        #if DEBUG
        backgroundColor = ProcessInfo.processInfo.environment["CMUX_UITEST_CHROME_DEBUG"] == "1"
            ? UIColor.systemRed.withAlphaComponent(0.22)
            : .clear
        #endif
    }
}
#endif
