#if canImport(UIKit)
  import UIKit

  @MainActor
  final class ScrollToBottomButton: UIButton {
    var onTap: (() -> Void)?

    static let diameter: CGFloat = 40

    private let backgroundView = UIVisualEffectView(
      effect: UIBlurEffect(style: .systemThinMaterial))
    private let iconView = UIImageView(image: UIImage(systemName: "arrow.down"))

    override init(frame: CGRect) {
      super.init(frame: frame)
      isAccessibilityElement = true
      accessibilityIdentifier = "terminal.scrollToBottom"
      accessibilityLabel = String(
        localized: "terminal.input_accessory.scroll_to_bottom",
        defaultValue: "Scroll to Bottom"
      )

      backgroundView.isUserInteractionEnabled = false
      backgroundView.clipsToBounds = true
      addSubview(backgroundView)

      iconView.isUserInteractionEnabled = false
      iconView.tintColor = .label
      iconView.contentMode = .scaleAspectFit
      addSubview(iconView)

      addTarget(self, action: #selector(handleTap), for: .touchUpInside)
    }

    @available(*, unavailable, message: "Use init(frame:) instead.")
    required init?(coder: NSCoder) {
      return nil
    }

    override var intrinsicContentSize: CGSize {
      CGSize(width: Self.diameter, height: Self.diameter)
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      backgroundView.frame = bounds
      backgroundView.layer.cornerRadius = bounds.height / 2
      let iconSide: CGFloat = 18
      iconView.frame = CGRect(
        x: (bounds.width - iconSide) / 2,
        y: (bounds.height - iconSide) / 2,
        width: iconSide,
        height: iconSide
      )
    }

    @objc private func handleTap() {
      onTap?()
    }
  }
#endif
