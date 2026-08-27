use crate::generated::{
    AttachSurfaceRequest, AttachSurfaceRequestMode, IdentifyRequest, IdentifyResult,
    ListWorkspacesRequest, NewWorkspaceRequest, ReadScreenRequest, ReadScreenResult, SendRequest,
    SubscribeRequest, SubscribeRequestTreeEvents, SurfaceResult, Tree,
};
use crate::{CmuxClient, CmuxStream, Optional, Result};

/// Handwritten builder for a typed subscribe stream.
#[derive(Debug, Clone, Copy, Default)]
pub struct SubscriptionBuilder {
    deltas: bool,
    surface: Option<u64>,
}

impl SubscriptionBuilder {
    pub const fn coarse() -> Self {
        Self { deltas: false, surface: None }
    }

    pub const fn deltas() -> Self {
        Self { deltas: true, surface: None }
    }

    pub const fn for_surface(mut self, surface: u64) -> Self {
        self.surface = Some(surface);
        self
    }

    pub fn open(self, client: &mut CmuxClient) -> Result<CmuxStream> {
        client.subscribe(SubscribeRequest {
            tree_events: Optional::Value(if self.deltas {
                SubscribeRequestTreeEvents::Deltas
            } else {
                SubscribeRequestTreeEvents::Coarse
            }),
            surface: self.surface.map_or(Optional::Missing, Optional::Value),
        })
    }
}

/// Handwritten builder for byte, render, or browser attachment streams.
#[derive(Debug, Clone, Copy)]
pub struct AttachBuilder {
    surface: u64,
    mode: AttachSurfaceRequestMode,
    initial_size: Option<(u16, u16)>,
}

impl AttachBuilder {
    pub const fn bytes(surface: u64) -> Self {
        Self { surface, mode: AttachSurfaceRequestMode::Bytes, initial_size: None }
    }

    pub const fn render(surface: u64) -> Self {
        Self { surface, mode: AttachSurfaceRequestMode::Render, initial_size: None }
    }

    /// Browser attachments use byte mode on the wire. The surface kind selects
    /// the browser-state and frame event stream.
    pub const fn browser(surface: u64) -> Self {
        Self::bytes(surface)
    }

    pub const fn initial_size(mut self, cols: u16, rows: u16) -> Self {
        self.initial_size = Some((cols, rows));
        self
    }

    pub fn open(self, client: &mut CmuxClient) -> Result<CmuxStream> {
        let (cols, rows) =
            self.initial_size.map_or((Optional::Missing, Optional::Missing), |(cols, rows)| {
                (Optional::Value(cols), Optional::Value(rows))
            });
        client.attach_surface(AttachSurfaceRequest {
            surface: self.surface,
            mode: Optional::Value(self.mode),
            cols,
            rows,
        })
    }
}

impl CmuxClient {
    pub fn identify_server(&mut self) -> Result<IdentifyResult> {
        self.identify(IdentifyRequest::default())
    }

    pub fn workspace_tree(&mut self) -> Result<Tree> {
        self.list_workspaces(ListWorkspacesRequest::default())
    }

    pub fn send_text(&mut self, surface: u64, text: impl Into<String>) -> Result<()> {
        self.send(SendRequest {
            surface,
            text: Optional::Value(text.into()),
            bytes: Optional::Missing,
            paste: None,
        })
        .map(|_| ())
    }

    pub fn send_base64(&mut self, surface: u64, bytes: impl Into<String>) -> Result<()> {
        self.send(SendRequest {
            surface,
            text: Optional::Missing,
            bytes: Optional::Value(bytes.into()),
            paste: None,
        })
        .map(|_| ())
    }

    pub fn send_paste(&mut self, surface: u64, text: impl Into<String>) -> Result<()> {
        self.send(SendRequest {
            surface,
            text: Optional::Value(text.into()),
            bytes: Optional::Missing,
            paste: Some(true),
        })
        .map(|_| ())
    }

    pub fn read_surface(&mut self, surface: u64) -> Result<ReadScreenResult> {
        self.read_screen(ReadScreenRequest { surface })
    }

    pub fn new_workspace_simple(
        &mut self,
        name: Option<&str>,
        size: Option<(u16, u16)>,
    ) -> Result<SurfaceResult> {
        let (cols, rows) = size.map_or((Optional::Missing, Optional::Missing), |(cols, rows)| {
            (Optional::Value(cols), Optional::Value(rows))
        });
        self.new_workspace(NewWorkspaceRequest {
            name: name.map_or(Optional::Missing, |name| Optional::Value(name.to_owned())),
            cols,
            rows,
        })
    }
}
