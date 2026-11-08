use crate::generated::{
    Id, LivePane, Pane as RawPane, Screen as RawScreen, Tab as RawTab, TabKind, Tree,
    Workspace as RawWorkspace,
};

/// Borrowed workspace-tree context for a surface.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SurfaceContext<'a> {
    /// Workspace containing the surface.
    pub workspace: &'a RawWorkspace,
    /// Screen containing the surface.
    pub screen: &'a RawScreen,
    /// Live pane containing the surface.
    pub pane: &'a LivePane,
    /// Tab that owns the surface.
    pub tab: &'a RawTab,
}

impl Tree {
    /// Finds a surface and returns its full workspace, screen, pane, and tab context.
    ///
    /// The lookup includes browser and dead tabs. Tombstoned panes have no tabs
    /// or surface identifiers and therefore cannot produce a context.
    pub fn find_surface(&self, surface: Id) -> Option<SurfaceContext<'_>> {
        for workspace in &self.workspaces {
            for screen in &workspace.screens {
                for pane in &screen.panes {
                    let RawPane::LivePane(pane) = pane else {
                        continue;
                    };
                    if let Some(tab) = pane.tabs.iter().find(|tab| tab.surface == surface) {
                        return Some(SurfaceContext { workspace, screen, pane, tab });
                    }
                }
            }
        }
        None
    }

    /// Returns the active workspace's active screen, pane, and tab when it is a live PTY.
    ///
    /// This selector is strict: it does not fall back to an inactive workspace,
    /// screen, pane, or tab when any active link is absent or points at a dead
    /// or browser tab.
    pub fn active_live_pty(&self) -> Option<SurfaceContext<'_>> {
        let workspace = self.workspaces.iter().find(|workspace| workspace.active)?;
        let screen = workspace.screens.iter().find(|screen| screen.active)?;
        let pane = screen.panes.iter().find_map(|pane| match pane {
            RawPane::LivePane(pane) if pane.id == screen.active_pane => Some(pane),
            RawPane::LivePane(_) | RawPane::DeadPane(_) => None,
        })?;
        let active_tab = usize::try_from(pane.active_tab).ok()?;
        let tab = pane.tabs.get(active_tab)?;
        if !tab.dead && tab.kind == TabKind::Pty {
            Some(SurfaceContext { workspace, screen, pane, tab })
        } else {
            None
        }
    }
}
