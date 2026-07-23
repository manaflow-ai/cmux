import CoreGraphics

/// Computes stable onboarding placement beside the System Settings window.
struct ComputerUseOnboardingWindowPlacement: Sendable {
    let gap: CGFloat
    let screenInset: CGFloat

    init(gap: CGFloat = 12, screenInset: CGFloat = 16) {
        self.gap = gap
        self.screenInset = screenInset
    }

    func appKitFrame(fromQuartz frame: CGRect, primaryScreenMaxY: CGFloat) -> CGRect {
        CGRect(
            x: frame.minX,
            y: primaryScreenMaxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    func visibleFrame(containing target: CGRect, candidates: [CGRect]) -> CGRect? {
        guard let bestMatch = candidates.max(by: { lhs, rhs in
            lhs.intersection(target).area < rhs.intersection(target).area
        }) else { return nil }
        return bestMatch.intersection(target).area > 0 ? bestMatch : nil
    }

    func frame(onboardingSize: CGSize, beside target: CGRect, in visibleFrame: CGRect) -> CGRect {
        let availableFrame = visibleFrame.insetBy(dx: screenInset, dy: screenInset)
        let leftOriginX = target.minX - gap - onboardingSize.width
        let rightOriginX = target.maxX + gap
        let leftFits = leftOriginX >= availableFrame.minX
        let rightFits = rightOriginX + onboardingSize.width <= availableFrame.maxX
        let leftSpace = target.minX - availableFrame.minX
        let rightSpace = availableFrame.maxX - target.maxX

        let preferredOriginX: CGFloat
        if leftFits, !rightFits {
            preferredOriginX = leftOriginX
        } else if rightFits, !leftFits {
            preferredOriginX = rightOriginX
        } else if leftSpace >= rightSpace {
            preferredOriginX = leftOriginX
        } else {
            preferredOriginX = rightOriginX
        }

        let maximumOriginX = max(availableFrame.minX, availableFrame.maxX - onboardingSize.width)
        let maximumOriginY = max(availableFrame.minY, availableFrame.maxY - onboardingSize.height)
        let originX = min(max(preferredOriginX, availableFrame.minX), maximumOriginX)
        let originY = min(
            max(target.maxY - onboardingSize.height, availableFrame.minY),
            maximumOriginY
        )
        return CGRect(origin: CGPoint(x: originX, y: originY), size: onboardingSize)
    }
}

private extension CGRect {
    var area: CGFloat {
        isNull || isEmpty ? 0 : width * height
    }
}
