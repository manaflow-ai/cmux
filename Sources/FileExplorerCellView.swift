import AppKit
import UniformTypeIdentifiers

final class FileExplorerCellView: NSTableCellView {
    private let iconView = FileExplorerIconView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let gitStatusLabel = NSTextField(labelWithString: "")
    private let loadingIndicator = NSProgressIndicator()
    private var trackingArea: NSTrackingArea?
    var onHover: ((Bool) -> Void)?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var iconWidthConstraint: NSLayoutConstraint!
    private var iconHeightConstraint: NSLayoutConstraint!
    private var iconToTextConstraint: NSLayoutConstraint!
    private var gitStatusWidthConstraint: NSLayoutConstraint!
    private var loadingWidthConstraint: NSLayoutConstraint!

    private func setupViews() {
        iconView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1

        gitStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        gitStatusLabel.alignment = .center
        gitStatusLabel.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        gitStatusLabel.isHidden = true
        gitStatusLabel.setAccessibilityIdentifier("FileExplorerGitStatusIndicator")

        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .small
        loadingIndicator.isHidden = true
        loadingIndicator.setAccessibilityIdentifier("FileExplorerLoadingIndicator")

        addSubview(iconView)
        addSubview(nameLabel)
        addSubview(gitStatusLabel)
        addSubview(loadingIndicator)

        iconWidthConstraint = iconView.widthAnchor.constraint(equalToConstant: 16)
        iconHeightConstraint = iconView.heightAnchor.constraint(equalToConstant: 16)
        iconToTextConstraint = nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4)
        gitStatusWidthConstraint = gitStatusLabel.widthAnchor.constraint(equalToConstant: 0)
        loadingWidthConstraint = loadingIndicator.widthAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconWidthConstraint,
            iconHeightConstraint,

            iconToTextConstraint,
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: gitStatusLabel.leadingAnchor, constant: -2),

            gitStatusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            gitStatusLabel.trailingAnchor.constraint(equalTo: loadingIndicator.leadingAnchor, constant: -3),
            gitStatusWidthConstraint,

            loadingIndicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            loadingIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            loadingWidthConstraint,
            loadingIndicator.heightAnchor.constraint(equalToConstant: 12),
        ])
    }

    func configure(with node: FileExplorerNode, gitStatus: GitFileStatus? = nil) {
        assert(Thread.isMainThread, "AppKit image updates must run on the main thread")
        let style = FileExplorerStyle.current
        nameLabel.stringValue = node.name
        nameLabel.font = style.nameFont
        iconWidthConstraint.constant = style.iconSize
        iconHeightConstraint.constant = style.iconSize
        iconToTextConstraint.constant = style.iconToTextSpacing

        if style == .finder {
            // Native Finder icon pixels miss 3:1 in light mode; use their masks with the dynamic palette tint.
            if node.isDirectory {
                iconView.configure(
                    image: NSWorkspace.shared.icon(for: .folder),
                    size: style.iconSize,
                    tintColor: style.folderIconTint
                )
            } else {
                let pathExtension = (node.name as NSString).pathExtension
                iconView.configure(
                    image: NSWorkspace.shared.icon(for: UTType(filenameExtension: pathExtension) ?? .data),
                    size: style.iconSize,
                    tintColor: style.fileIconTint
                )
            }
        } else {
            if node.isDirectory {
                iconView.configure(
                    systemSymbol: "folder.fill",
                    size: style.iconSize,
                    tintColor: style.folderIconTint,
                    symbolWeight: style.iconWeight
                )
            } else {
                iconView.configure(
                    descriptor: FileExplorerIconDescriptor(fileName: node.name),
                    size: style.iconSize,
                    symbolWeight: style.iconWeight
                )
            }
        }

        if node.isLoading {
            loadingWidthConstraint.constant = 12
            loadingIndicator.isHidden = false
            loadingIndicator.startAnimation(nil)
        } else {
            loadingWidthConstraint.constant = 0
            loadingIndicator.isHidden = true
            loadingIndicator.stopAnimation(nil)
        }

        if let gitStatus {
            gitStatusWidthConstraint.constant = 14
            gitStatusLabel.stringValue = gitStatus.indicator
            gitStatusLabel.textColor = style.gitColor(for: gitStatus)
            gitStatusLabel.toolTip = node.path
            gitStatusLabel.isHidden = false
        } else {
            gitStatusWidthConstraint.constant = 0
            gitStatusLabel.stringValue = ""
            gitStatusLabel.toolTip = nil
            gitStatusLabel.isHidden = true
        }

        if let error = node.error {
            nameLabel.textColor = .systemRed
            nameLabel.toolTip = error
        } else if let gitStatus {
            nameLabel.textColor = style.gitColor(for: gitStatus)
            nameLabel.toolTip = node.path
        } else {
            nameLabel.textColor = .labelColor
            nameLabel.toolTip = node.path
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }
}
