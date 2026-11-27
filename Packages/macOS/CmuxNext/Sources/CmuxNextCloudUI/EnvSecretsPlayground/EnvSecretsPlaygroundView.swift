#if DEBUG
import AppKit
import CmuxNextDesign

/// DEBUG ONLY (Environment Secrets Playground): the picker chrome (direction, state, light or dark) over
/// one direction drawn full size. The chrome is not a contestant: plain system controls. Cmd-1, Cmd-2 and
/// Cmd-3 pick a direction; Cmd-[ and Cmd-] step through the states. Every change rebuilds the chrome and
/// the direction from the model (a playground of fixed sample data: a few dozen views).
final class EnvSecretsPlaygroundView: NSView {
    private let model: EnvSecretsPlaygroundModel
    private let applyLook: @MainActor () -> Void

    /// - Parameters:
    ///   - model: the direction, state, look and live picks.
    ///   - applyLook: sets the window's appearance from ``EnvSecretsPlaygroundModel/dark``.
    init(model: EnvSecretsPlaygroundModel, applyLook: @escaping @MainActor () -> Void) {
        self.model = model
        self.applyLook = applyLook
        super.init(frame: NSRect(x: 0, y: 0, width: 1180, height: 820))
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        EnvInk.canvas.setFill()
        bounds.fill()
    }

    /// Draws the chrome and the picked direction again from the model.
    func reload() {
        let reload: @MainActor () -> Void = { [weak self] in self?.reload() }
        let content: NSView = switch model.direction {
        case .ledger: EnvLedgerDirection(model: model, reload: reload).make()
        case .sentences: EnvSentencesDirection(model: model, reload: reload).make()
        case .inspector: EnvInspectorDirection(model: model, reload: reload).make()
        }
        let column = envV([chrome(), envDivider(), content], spacing: 0, fill: true)
        column.translatesAutoresizingMaskIntoConstraints = false
        content.setContentHuggingPriority(.init(1), for: .vertical)
        subviews = [column]
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor), column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor), column.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 1040), heightAnchor.constraint(greaterThanOrEqualToConstant: 700),
        ])
    }

    private func chrome() -> NSView {
        let directions = EnvSecretsPlaygroundModel.Direction.allCases
        let directionPicker = envSized(EnvSegmented(directions.map { "\($0.rawValue) \($0.title)" },
                                                    selected: directions.firstIndex(of: model.direction) ?? 0) { [weak self] index in
            self?.model.direction = directions[index]
            self?.reload()
        }, width: 330)
        let looks: [Bool?] = [nil, false, true]
        let lookPicker = envSized(EnvSegmented(["App", "Light", "Dark"], selected: looks.firstIndex(of: model.dark) ?? 0) { [weak self] index in
            self?.model.dark = looks[index]
            self?.applyLook()
        }, width: 170)
        let top = envH([directionPicker, envLabel(model.direction.axis, size: TypeScale.caption, color: EnvInk.secondary), envSpacer(), lookPicker], spacing: 14)
        let pills: [NSView] = EnvSecretsPlaygroundModel.Scene.allCases.map { scene in  // visible-only: the ten states
            let on = model.scene == scene
            let pill = EnvBox(envLabel("\(scene.rawValue + 1). \(scene.title)", size: TypeScale.caption, weight: .semibold,
                                       color: on ? .white : EnvInk.secondary),
                              padding: envPad(h: 8, v: 3), fill: on ? .controlAccentColor : nil, corner: .capsule)
            return EnvClickArea(pill) { [weak self] in self?.model.scene = scene; self?.reload() }
        }
        let bottom = envH(pills + [envSpacer(), envLabel("Sample data only", size: TypeScale.caption, color: EnvInk.tertiary)], spacing: 4)
        return EnvBox(envV([top, bottom], spacing: 8, fill: true), padding: envPad(h: 14, v: 9))
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let key = event.charactersIgnoringModifiers else { return super.performKeyEquivalent(with: event) }
        if let number = Int(key), let direction = EnvSecretsPlaygroundModel.Direction(rawValue: number) {
            model.direction = direction
        } else if key == "[" || key == "]" {
            let all = EnvSecretsPlaygroundModel.Scene.allCases
            model.scene = all[(model.scene.rawValue + (key == "]" ? 1 : -1) + all.count) % all.count]
        } else {
            return super.performKeyEquivalent(with: event)
        }
        reload()
        return true
    }
}
#endif
