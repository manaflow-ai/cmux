public import AppKit
import CoreImage

/// A renamed title rolls its words as the agent chat's live line does when a tool call changes
/// (webviews conversation.css `cv-roll-*`; Leo, 2026-11-08: "i feel like when workspaces get
/// renamed (esp by agents) it should have that same fade in animation that the tool call situation
/// has..."): the old words rise 0.6 em, soften and fade out above while the new rise in from
/// 0.6 em below, on the `fadeIn` token (the chat's `--agent-motion-in`, 120 ms). Opacity,
/// transform and a 2 pt blur only, so nothing reflows and `ui.animationSpeed` scales it.
extension MotionGate {
    /// The outgoing copy's layer name: a newer roll removes the copy an older one left.
    static let rollOutName = "cmux.titleRoll.out"
    static let blurPath = "filters.blur.inputRadius"

    /// Rolls `text` from `old` to the string it now holds. Call after setting the new string and
    /// before the owner lays `text` out again: its frame and mask still fit `old`, and the outgoing
    /// copy takes them. False (nothing added) when movement does not animate (Reduce Motion, speed
    /// off), the view cannot animate, either title is empty or nothing changed; the owner then
    /// swaps or crossfades as before. `flipped`: the host's y runs down (a flipped view's space; Core
    /// Animation's `contentsAreFlipped` misses a plain layer tree inside a flipped view).
    @discardableResult
    public func rollTitle(_ text: ChromeTextLayer, from old: String, flipped: Bool, in view: NSView?) -> Bool {
        // A hidden title (a pinned or narrow tab's) stays hidden: its old words never flash.
        guard let host = text.superlayer, !text.isHidden, text.opacity > 0, !old.isEmpty, !text.string.isEmpty, old != text.string,
              animatesMovement(in: view?.window ?? Motion.window(showing: text)), canAnimate(in: view),
              duration(.fadeIn) > 0 else { return false }
        host.sublayers?.filter { $0.name == Self.rollOutName }.forEach { $0.removeFromSuperlayer() }
        let out = ChromeTextLayer()
        out.name = Self.rollOutName
        out.actions = text.actions
        out.font = text.font
        out.truncation = text.truncation
        out.alignmentMode = text.alignmentMode
        out.foregroundColor = text.foregroundColor
        out.contentsScale = text.contentsScale
        out.string = old
        // The 0.6 em the words travel, up on screen whichever way the host's y runs.
        let rise = (text.font.pointSize * 0.6).rounded() * (flipped ? -1 : 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        out.frame = text.frame
        out.transform = text.transform
        if let mask = text.mask as? CAGradientLayer { out.mask = Self.copy(mask) }
        out.filters = Self.blur()
        text.filters = Self.blur()
        host.insertSublayer(out, below: text)
        TitleRollEnd(out: out, text: text, host: host).onCommitEnd()
        set(out, "opacity", to: Float(0), fade: .fadeIn, from: Float(1))
        set(out, "transform.translation.y", to: rise, fade: .fadeIn, from: CGFloat(0))
        // The blur's radius is no model key (KVC would throw), so it only animates.
        out.add(scheduledFade(.fadeIn, Self.blurPath, from: CGFloat(0), to: CGFloat(2), after: 0, on: out), forKey: Self.blurPath)
        // The new words land on the model values the owner gave them.
        let shown = text.opacity, rest = text.transform.m42 // the transform's y translation
        set(text, "opacity", to: shown, fade: .fadeIn, from: Float(0))
        set(text, "transform.translation.y", to: rest, fade: .fadeIn, from: rest - rise)
        text.add(scheduledFade(.fadeIn, Self.blurPath, from: CGFloat(2), to: CGFloat(0), after: 0, on: text), forKey: Self.blurPath)
        CATransaction.commit()
        return true
    }

    /// Ends `text`'s roll at once: its outgoing words go and the title stands at rest. A recycled
    /// row calls it, so a roll never carries one workspace's name over another's.
    public func cancelTitleRoll(_ text: ChromeTextLayer) {
        text.superlayer?.sublayers?.filter { $0.name == Self.rollOutName }.forEach { $0.removeFromSuperlayer() }
        for key in ["opacity", "transform.translation.y", Self.blurPath] { text.removeAnimation(forKey: key) }
        text.filters = nil
    }

    /// A Gaussian blur at radius 0, named so `filters.blur.inputRadius` animates it.
    private static func blur() -> [CIFilter] {
        guard let filter = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 0]) else { return [] }
        filter.name = "blur"
        return [filter]
    }

    /// The title's clip and end fade at its old width, for the outgoing words.
    private static func copy(_ mask: CAGradientLayer) -> CAGradientLayer {
        let copy = CAGradientLayer()
        copy.actions = mask.actions
        copy.frame = mask.frame
        copy.colors = mask.colors
        copy.locations = mask.locations
        copy.startPoint = mask.startPoint
        copy.endPoint = mask.endPoint
        copy.transform = mask.transform
        return copy
    }
}

/// Removes a roll's outgoing words, and the title's blur unless a newer roll still runs, when the
/// roll's transaction ends.
struct TitleRollEnd {
    let out: CALayer, text: CALayer, host: CALayer

    /// Call inside the roll's open transaction.
    func onCommitEnd() {
        CATransaction.setCompletionBlock { [out, text, host] in
            MainActor.assumeIsolated { // main-proof: CATransaction.h: the completion block is called on the main thread
                out.removeFromSuperlayer()
                guard host.sublayers?.contains(where: { $0.name == MotionGate.rollOutName }) != true,
                      text.superlayer === host else { return }
                text.removeAnimation(forKey: MotionGate.blurPath)
                text.filters = nil
            }
        }
    }
}
