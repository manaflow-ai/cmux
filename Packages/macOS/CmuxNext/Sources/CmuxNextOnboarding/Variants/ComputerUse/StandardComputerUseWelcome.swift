// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CmuxNextDesign

/// The first-run Computer Use page: leading title and line, the looping blue-cursor picture, one
/// line about the cursor and Settings, then Not Now and Allow Access, on full-window glass.
struct StandardComputerUseWelcome: OnboardingScreenVariant {
    static let step = OnboardingModel.Step.computerUseWelcome
    static let surface = OnboardingSurface.fullGlass
    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        OnboardingScaffold.make(title: OnboardingStrings.computerUseWelcomeTitle, subtitle: OnboardingStrings.computerUseWelcomeBody,
                                body: ComputerUseWelcomeBody(), context: context)
    }
}

/// The picture, centered, and the line under it.
final class ComputerUseWelcomeBody: NSView {
    let illustration = ComputerUseCursorIllustration()
    let detail = OnboardingLabel.make(OnboardingStrings.computerUseWelcomeDetail, color: Palette.textSecondary, lines: 3)

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        detail.setAccessibilityIdentifier("cmux.onboarding.computerUseWelcome.detail")
        for view in [illustration, detail] as [NSView] { addSubview(view) }
        NSLayoutConstraint.activate([
            illustration.topAnchor.constraint(equalTo: topAnchor),
            illustration.centerXAnchor.constraint(equalTo: centerXAnchor),
            illustration.widthAnchor.constraint(equalToConstant: ComputerUseCursorIllustration.size.width),
            illustration.heightAnchor.constraint(equalToConstant: ComputerUseCursorIllustration.size.height),
            detail.topAnchor.constraint(equalTo: illustration.bottomAnchor, constant: 16),
            detail.leadingAnchor.constraint(equalTo: leadingAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            detail.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
