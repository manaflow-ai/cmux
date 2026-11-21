#if DEBUG
import CmuxNextDesign
import SwiftUI

/// DEBUG ONLY (Environment Secrets Playground): the picker chrome (direction, state, light or dark)
/// over one direction drawn full size. The chrome is not a contestant: plain system controls.
/// Cmd-1, Cmd-2 and Cmd-3 pick a direction; Cmd-[ and Cmd-] step through the states.
struct EnvSecretsPlaygroundView: View {
    @Bindable var model: EnvSecretsPlaygroundModel
    /// Sets the window's appearance from ``EnvSecretsPlaygroundModel/dark``.
    let applyLook: @MainActor () -> Void

    var body: some View {
        VStack(spacing: 0) {
            chrome
            Divider()
            Group {
                switch model.direction {
                case .ledger: EnvLedgerDirection(model: model)
                case .sentences: EnvSentencesDirection(model: model)
                case .inspector: EnvInspectorDirection(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(EnvInk.canvas)
        }
        .frame(minWidth: 1040, minHeight: 700)
        .onChange(of: model.dark) { applyLook() }
    }

    private var chrome: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Picker("Direction", selection: $model.direction) {
                    ForEach(EnvSecretsPlaygroundModel.Direction.allCases) { Text("\($0.rawValue) \($0.title)").tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 330)
                Text(model.direction.axis).font(.system(size: TypeScale.caption)).foregroundStyle(EnvInk.secondary).lineLimit(1)
                Spacer()
                Picker("Look", selection: $model.dark) {
                    Text("App").tag(Bool?.none)
                    Text("Light").tag(Bool?.some(false))
                    Text("Dark").tag(Bool?.some(true))
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 170)
            }
            HStack(spacing: 4) {
                ForEach(EnvSecretsPlaygroundModel.Scene.allCases) { scene in
                    Button { model.scene = scene } label: {
                        Text("\(scene.rawValue + 1). \(scene.title)").font(.system(size: TypeScale.caption, weight: .semibold))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(model.scene == scene ? Color.accentColor : Color.clear))
                            .foregroundStyle(model.scene == scene ? Color.white : EnvInk.secondary)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.cmuxPressFillCapsule)
                }
                Spacer()
                Text("Sample data only").font(.system(size: TypeScale.caption)).foregroundStyle(EnvInk.tertiary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(shortcuts)
    }

    /// Hidden buttons that carry the picker's keys.
    private var shortcuts: some View {
        ZStack {
            ForEach(EnvSecretsPlaygroundModel.Direction.allCases) { direction in
                Button("") { model.direction = direction }
                    .keyboardShortcut(KeyEquivalent(Character("\(direction.rawValue)")), modifiers: .command)
            }
            Button("") { step(-1) }.keyboardShortcut("[", modifiers: .command)
            Button("") { step(1) }.keyboardShortcut("]", modifiers: .command)
        }
        .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
    }

    private func step(_ by: Int) {
        let all = EnvSecretsPlaygroundModel.Scene.allCases
        let next = (model.scene.rawValue + by + all.count) % all.count
        model.scene = all[next]
    }
}
#endif
