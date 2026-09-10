import Foundation

/// What a cloud machine is for, independent of which image id the control
/// plane happens to deploy for it today.
///
/// Clients request machines by kind and let the backend map the kind to the
/// image its environment supports (the provider's `_DESKTOP_IMAGE` selector,
/// its base image selector, or the deployed manifest default). Pinning an
/// image id on the client broke every build whose id drifted from the web
/// deploy's manifest (`vm_image_config_error`), so the id is never sent unless
/// a person passes `--image` explicitly.
enum VMMachineKind: String, CaseIterable, Sendable, Equatable {
    /// Devtools, coding agents, and a desktop with a noVNC screen.
    case desktop
    /// Shell-only machine: same devtools, no screen.
    case base

    /// The kind an image id implies when the backend did not say. Older
    /// control planes omit `kind`; a desktop image carries a recognizable
    /// name, everything else is a shell box.
    ///
    /// Only VNC markers count. `devbox` used to imply a desktop because one
    /// provider's devbox image bundled xfce + noVNC; the shared devbox image
    /// every remaining provider boots is shell-only, so matching it here
    /// published a Desktop surface for machines with no screen.
    static func inferred(fromImage image: String) -> VMMachineKind {
        let lowered = image.lowercased()
        return lowered.contains("xfce") || lowered.contains("vnc") ? .desktop : .base
    }

    /// The kind a backend payload describes: its explicit `kind` field when
    /// present and valid, otherwise inferred from the image id.
    static func resolved(kind rawKind: Any?, image: Any?) -> VMMachineKind {
        if let raw = rawKind as? String, let kind = VMMachineKind(rawValue: raw.lowercased()) {
            return kind
        }
        return inferred(fromImage: (image as? String) ?? "")
    }

    var hasDesktop: Bool { self == .desktop }

    var displayName: String {
        switch self {
        case .desktop:
            return String(localized: "machines.kind.desktop", defaultValue: "Desktop")
        case .base:
            return String(localized: "machines.kind.base", defaultValue: "Base")
        }
    }

    /// One line on what the kind gives you, for the New Machine sheet.
    var summary: String {
        switch self {
        case .desktop:
            return String(
                localized: "machines.new.kind.desktop.summary",
                defaultValue: "Terminal plus a screen you can watch and control. Best for browsers and GUI apps."
            )
        case .base:
            return String(
                localized: "machines.new.kind.base.summary",
                defaultValue: "Terminal only. Boots faster and uses less memory."
            )
        }
    }
}

/// Which image the backend will provision for a kind, as `GET /api/vm`
/// reports it under `limits.imageKinds`. Display-only: the client never sends
/// the image back.
struct VMImageKindOption: Equatable, Sendable {
    let kind: VMMachineKind
    let image: String
}
