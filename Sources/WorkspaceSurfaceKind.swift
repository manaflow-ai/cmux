extension Workspace {
    func surfaceKind(for panel: any Panel) -> String {
        switch panel.panelType {
        case .terminal:
            return SurfaceKind.terminal
        case .browser:
            return SurfaceKind.browser
        case .markdown:
            return SurfaceKind.markdown
        case .filePreview:
            return SurfaceKind.filePreview
        case .simulator:
            return SurfaceKind.simulator
        }
    }
}
