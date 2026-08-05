use super::client::Client;
use super::id::*;
use super::model::*;
use super::ops;
use super::options::*;
use super::typed_stream::{
    BrowserAttachment, SessionEventStream, SessionJournalStream, SidebarViewStream,
    TerminalAttachment,
};
use super::wire::{self, Params, field};
use crate::{Error, Result};
use base64::Engine;
use serde::de::DeserializeOwned;
use serde_json::{Map, Value};

fn receipt(value: &Value) -> Result<MutationReceipt> {
    wire::mutation_meta(value)
}

fn mutation_result<T>(
    value: Value,
    decode: impl FnOnce(&Value) -> Result<T>,
) -> Result<MutationResult<T>> {
    let meta = receipt(&value)?;
    let decoded = decode(wire::mutation_value(&value)?)?;
    Ok(MutationResult {
        value: decoded,
        generation: meta.generation,
        revision: meta.revision,
        replayed: meta.replayed,
    })
}

fn mutation_empty(value: Value) -> Result<MutationReceipt> {
    mutation_result(value, decode_empty)
}

fn decode_empty(value: &Value) -> Result<()> {
    if !value.as_object().is_some_and(Map::is_empty) {
        return Err(Error::UnexpectedEnvelope(
            "empty result must be an object with no fields".to_string(),
        ));
    }
    Ok(())
}

fn created<T>(
    value: Value,
    resource: impl FnOnce(&CreatedPath) -> Result<T>,
) -> Result<Created<T>> {
    let path = wire::created_path(wire::mutation_value(&value)?)?;
    let resource = resource(&path)?;
    mutation_result(value, |_| Ok(path)).map(|result| Created {
        resource,
        value: result.value,
        generation: result.generation,
        revision: result.revision,
        replayed: result.replayed,
    })
}

fn mutation_snapshot<T: DeserializeOwned>(
    value: Value,
    key: &'static str,
) -> Result<MutationResult<T>> {
    mutation_result(value, |value| wire::snapshot::<T>(value, key))
}

fn label_params(options: LabelOptions) -> Params {
    Params::new().value(field::NAME, options.name.map_or(Value::Null, Value::String))
}

fn metadata_params(options: ClientMetadataOptions) -> Result<Params> {
    if matches!(&options.name, Update::Unchanged) && matches!(&options.kind, Update::Unchanged) {
        return Err(Error::InvalidArgument(
            "client metadata update must change name or kind".to_string(),
        ));
    }
    let mut params = Params::new();
    params = match options.name {
        Update::Unchanged => params,
        Update::Clear => params.value(field::NAME, Value::Null),
        Update::Set(name) => params.string(field::NAME, name),
    };
    Ok(match options.kind {
        Update::Unchanged => params,
        Update::Clear => params.value(field::KIND, Value::Null),
        Update::Set(kind) => params.string(field::KIND, kind),
    })
}

impl Client {
    pub fn machine(&self, selector: impl Into<Selector<MachineId>>) -> Machine {
        Machine { client: self.clone(), selector: selector.into() }
    }

    pub fn current_machine(&self) -> Machine {
        self.machine(Selector::current())
    }

    pub fn machines(&self) -> Result<Vec<Machine>> {
        wire::list::<MachineSnapshot>(
            &self.read(ops::MACHINE_LIST, Params::new())?,
            "machines",
            "machine",
        )
        .map(|snapshots| snapshots.into_iter().map(|snapshot| self.machine(snapshot.id)).collect())
    }

    pub fn find_machines_by_name(&self, name: &str) -> Result<Vec<Machine>> {
        Ok(wire::list::<MachineSnapshot>(
            &self.read(ops::MACHINE_LIST, Params::new())?,
            "machines",
            "machine",
        )?
        .into_iter()
        .filter(|snapshot| snapshot.name == name)
        .map(|snapshot| self.machine(snapshot.id))
        .collect())
    }

    pub fn session(&self, selector: impl Into<Selector<SessionId>>) -> Session {
        Session { client: self.clone(), machine: Selector::current(), selector: selector.into() }
    }

    pub fn current_session(&self) -> Session {
        self.session(Selector::current())
    }

    pub fn sessions(&self) -> Result<Vec<Session>> {
        wire::list::<SessionSnapshot>(
            &self.read(
                ops::SESSION_LIST,
                Params::new().selector(field::MACHINE, &Selector::<MachineId>::current()),
            )?,
            "sessions",
            "session",
        )
        .map(|snapshots| snapshots.into_iter().map(|snapshot| self.session(snapshot.id)).collect())
    }

    pub fn find_sessions_by_name(&self, name: &str) -> Result<Vec<Session>> {
        Ok(wire::list::<SessionSnapshot>(
            &self.read(
                ops::SESSION_LIST,
                Params::new().selector(field::MACHINE, &Selector::<MachineId>::current()),
            )?,
            "sessions",
            "session",
        )?
        .into_iter()
        .filter(|snapshot| snapshot.name.as_deref() == Some(name))
        .map(|snapshot| self.session(snapshot.id))
        .collect())
    }
}

#[derive(Clone, Debug)]
pub struct Machine {
    client: Client,
    selector: Selector<MachineId>,
}

impl Machine {
    pub fn selector(&self) -> &Selector<MachineId> {
        &self.selector
    }

    pub fn id(&self) -> Option<&MachineId> {
        match &self.selector {
            Selector::Id(id) => Some(id),
            Selector::Current(_) | Selector::Name(_) => None,
        }
    }

    pub fn refresh(&self) -> Result<MachineSnapshot> {
        wire::snapshot(
            &self
                .client
                .read(ops::MACHINE_GET, Params::new().selector(field::MACHINE, &self.selector))?,
            "machine",
        )
    }

    pub fn sessions(&self) -> Result<Vec<Session>> {
        wire::list::<SessionSnapshot>(
            &self
                .client
                .read(ops::SESSION_LIST, Params::new().selector(field::MACHINE, &self.selector))?,
            "sessions",
            "session",
        )
        .map(|snapshots| {
            snapshots
                .into_iter()
                .map(|snapshot| Session {
                    client: self.client.clone(),
                    machine: self.selector.clone(),
                    selector: Selector::id(snapshot.id),
                })
                .collect()
        })
    }

    pub fn find_sessions_by_name(&self, name: &str) -> Result<Vec<Session>> {
        Ok(wire::list::<SessionSnapshot>(
            &self
                .client
                .read(ops::SESSION_LIST, Params::new().selector(field::MACHINE, &self.selector))?,
            "sessions",
            "session",
        )?
        .into_iter()
        .filter(|snapshot| snapshot.name.as_deref() == Some(name))
        .map(|snapshot| Session {
            client: self.client.clone(),
            machine: self.selector.clone(),
            selector: Selector::id(snapshot.id),
        })
        .collect())
    }

    pub fn open_session(
        &self,
        options: SessionOpenOptions,
    ) -> Result<MutationResult<SessionSnapshot>> {
        self.open_session_with(options, MutationOptions::unique()?)
    }

    pub fn open_session_with(
        &self,
        options: SessionOpenOptions,
        mutation: MutationOptions,
    ) -> Result<MutationResult<SessionSnapshot>> {
        let value = self.client.mutate(
            ops::SESSION_OPEN,
            Params::new()
                .selector(field::MACHINE, &self.selector)
                .selector(field::SESSION, &options.session),
            mutation,
        )?;
        mutation_snapshot(value, "session")
    }
}

#[derive(Clone, Debug)]
pub struct Session {
    client: Client,
    machine: Selector<MachineId>,
    selector: Selector<SessionId>,
}

#[derive(Clone, Debug)]
pub struct SessionCreation {
    session: Session,
}

impl SessionCreation {
    pub fn resolve(&self, correlation_key: impl Into<String>) -> Result<CreationResolution> {
        let correlation_key = correlation_key.into();
        if correlation_key.is_empty() || correlation_key.len() > 128 {
            return Err(Error::InvalidArgument(
                "correlation key must contain 1 to 128 UTF-8 bytes".to_string(),
            ));
        }
        wire::decode_exact(
            &self.session.client.read(
                ops::SESSION_CREATION_RESOLVE,
                self.session.params().string(field::CORRELATION_KEY, correlation_key),
            )?,
            "creation resolution",
        )
    }
}

impl Session {
    pub fn selector(&self) -> &Selector<SessionId> {
        &self.selector
    }

    pub fn id(&self) -> Option<&SessionId> {
        match &self.selector {
            Selector::Id(id) => Some(id),
            Selector::Current(_) | Selector::Name(_) => None,
        }
    }

    fn params(&self) -> Params {
        Params::new()
            .selector(field::MACHINE, &self.machine)
            .selector(field::SESSION, &self.selector)
    }

    pub fn refresh(&self) -> Result<SessionSnapshot> {
        wire::snapshot(&self.client.read(ops::SESSION_GET, self.params())?, "session")
    }

    pub fn creation(&self) -> SessionCreation {
        SessionCreation { session: self.clone() }
    }

    pub fn snapshot(&self) -> Result<ResourceSnapshot> {
        wire::decode_exact(
            &self.client.read(ops::SESSION_SNAPSHOT, self.params())?,
            "resource snapshot",
        )
    }

    pub fn events(&self, options: EventStreamOptions) -> Result<SessionEventStream> {
        self.client
            .stream(ops::SESSION_EVENTS, self.params().cursor(options.cursor.as_ref()))
            .map(SessionEventStream::new)
    }

    pub fn journal(&self, options: SessionJournalOptions) -> Result<SessionJournalStream> {
        if options.cursor.is_some() && options.start.is_some() {
            return Err(Error::InvalidArgument(
                "journal cursor and start are mutually exclusive".to_string(),
            ));
        }
        if options.max_sensitivity == Some(super::typed_stream::JournalSensitivity::Secret) {
            return Err(Error::InvalidArgument(
                "secret journal records are unavailable in v1".to_string(),
            ));
        }
        if options.subjects.iter().any(|subject| subject.kind.is_none() && subject.id.is_none()) {
            return Err(Error::InvalidArgument(
                "journal subject filters require kind or id".to_string(),
            ));
        }
        if options
            .regex
            .as_ref()
            .is_some_and(|regex| regex.pattern.is_empty() || regex.pattern.len() > 1024)
        {
            return Err(Error::InvalidArgument(
                "journal regex must contain 1 to 1024 UTF-8 bytes".to_string(),
            ));
        }
        let mut params = self.params().cursor(options.cursor.as_ref());
        if let Some(start) = options.start {
            params = params.string(
                "start",
                match start {
                    JournalStart::Tail => "tail",
                    JournalStart::Beginning => "beginning",
                },
            );
        }
        if let Some(follow) = options.follow {
            params = params.boolean("follow", follow);
        }
        let mut filter = Map::new();
        if !options.kinds.is_empty() {
            filter.insert("kinds".to_string(), serde_json::json!(options.kinds));
        }
        if !options.classes.is_empty() {
            filter.insert(
                "classes".to_string(),
                Value::Array(
                    options
                        .classes
                        .into_iter()
                        .map(|value| {
                            Value::String(
                                match value {
                                    super::typed_stream::JournalClass::State => "state",
                                    super::typed_stream::JournalClass::Observation => "observation",
                                    super::typed_stream::JournalClass::Effect => "effect",
                                    super::typed_stream::JournalClass::Checkpoint => "checkpoint",
                                }
                                .to_string(),
                            )
                        })
                        .collect(),
                ),
            );
        }
        if !options.subjects.is_empty() {
            filter.insert(
                "subjects".to_string(),
                Value::Array(
                    options
                        .subjects
                        .into_iter()
                        .map(|subject| {
                            let mut value = Map::new();
                            if let Some(kind) = subject.kind {
                                value.insert("kind".to_string(), Value::String(kind));
                            }
                            if let Some(id) = subject.id {
                                value.insert("id".to_string(), Value::String(id));
                            }
                            Value::Object(value)
                        })
                        .collect(),
                ),
            );
        }
        if let Some(sensitivity) = options.max_sensitivity {
            filter.insert(
                "max_sensitivity".to_string(),
                Value::String(
                    match sensitivity {
                        super::typed_stream::JournalSensitivity::Public => "public",
                        super::typed_stream::JournalSensitivity::Metadata => "metadata",
                        super::typed_stream::JournalSensitivity::Sensitive => "sensitive",
                        super::typed_stream::JournalSensitivity::Secret => unreachable!(),
                    }
                    .to_string(),
                ),
            );
        }
        if let Some(regex) = options.regex {
            filter.insert(
                "regex".to_string(),
                serde_json::json!({
                    "pattern":regex.pattern,
                    "field":regex.field.wire_name(),
                    "case_sensitive":regex.case_sensitive,
                }),
            );
        }
        if !filter.is_empty() {
            params = params.value("filter", Value::Object(filter));
        }
        self.client.stream(ops::SESSION_JOURNAL_SUBSCRIBE, params).map(SessionJournalStream::new)
    }

    pub fn ping(&self) -> Result<PingResult> {
        wire::decode_exact(
            &self.client.read(ops::SESSION_PING, self.params())?,
            "session ping result",
        )
    }

    pub fn shutdown(&self, options: ShutdownOptions) -> Result<MutationResult<ShutdownResult>> {
        self.shutdown_with(options, MutationOptions::unique()?)
    }

    pub fn shutdown_with(
        &self,
        options: ShutdownOptions,
        mutation: MutationOptions,
    ) -> Result<MutationResult<ShutdownResult>> {
        mutation_result(
            self.client.mutate(
                ops::SESSION_SHUTDOWN,
                self.params().optional_bool(field::FORCE, options.force),
                mutation,
            )?,
            |value| wire::decode_exact(value, "session shutdown result"),
        )
    }

    pub fn close(&self) -> Result<MutationResult<ShutdownResult>> {
        self.shutdown(ShutdownOptions::default())
    }

    pub fn reload_config(&self) -> Result<MutationResult<ReloadConfigResult>> {
        self.reload_config_with(MutationOptions::unique()?)
    }

    pub fn reload_config_with(
        &self,
        mutation: MutationOptions,
    ) -> Result<MutationResult<ReloadConfigResult>> {
        mutation_result(
            self.client.mutate(ops::SESSION_RELOAD_CONFIG, self.params(), mutation)?,
            |value| wire::decode_exact(value, "reload config result"),
        )
    }

    pub fn update_terminal_defaults(
        &self,
        options: TerminalDefaultsOptions,
    ) -> Result<MutationResult<TerminalDefaultsSnapshot>> {
        self.update_terminal_defaults_with(options, MutationOptions::unique()?)
    }

    pub fn update_terminal_defaults_with(
        &self,
        options: TerminalDefaultsOptions,
        mutation: MutationOptions,
    ) -> Result<MutationResult<TerminalDefaultsSnapshot>> {
        mutation_result(
            self.client.mutate(
                ops::SESSION_TERMINAL_DEFAULTS_UPDATE,
                self.params().extend(wire::terminal_defaults(options)?),
                mutation,
            )?,
            |value| wire::decode_exact(value, "terminal defaults result"),
        )
    }

    pub fn set_window_title(&self, title: impl Into<String>) -> Result<MutationReceipt> {
        self.set_window_title_with(title, MutationOptions::unique()?)
    }

    pub fn set_window_title_with(
        &self,
        title: impl Into<String>,
        mutation: MutationOptions,
    ) -> Result<MutationReceipt> {
        mutation_empty(self.client.mutate(
            ops::SESSION_WINDOW_TITLE_SET,
            self.params().string(field::TITLE, title),
            mutation,
        )?)
    }

    pub fn clear_window_title(&self) -> Result<MutationReceipt> {
        self.clear_window_title_with(MutationOptions::unique()?)
    }

    pub fn clear_window_title_with(&self, mutation: MutationOptions) -> Result<MutationReceipt> {
        mutation_empty(self.client.mutate(
            ops::SESSION_WINDOW_TITLE_CLEAR,
            self.params(),
            mutation,
        )?)
    }

    pub fn workspace(&self, selector: impl Into<Selector<WorkspaceId>>) -> Workspace {
        Workspace { session: self.clone(), selector: selector.into() }
    }

    pub fn current_workspace(&self) -> Workspace {
        self.workspace(Selector::current())
    }

    pub fn workspaces(&self) -> Result<Vec<Workspace>> {
        wire::list::<WorkspaceSnapshot>(
            &self.client.read(ops::WORKSPACE_LIST, self.params())?,
            "workspaces",
            "workspace",
        )
        .map(|snapshots| {
            snapshots.into_iter().map(|snapshot| self.workspace(snapshot.id)).collect()
        })
    }

    pub fn find_workspaces_by_name(&self, name: &str) -> Result<Vec<Workspace>> {
        Ok(wire::list::<WorkspaceSnapshot>(
            &self.client.read(ops::WORKSPACE_LIST, self.params())?,
            "workspaces",
            "workspace",
        )?
        .into_iter()
        .filter(|snapshot| snapshot.name == name)
        .map(|snapshot| self.workspace(snapshot.id))
        .collect())
    }

    pub fn create_workspace(&self, name: Option<String>) -> Result<Created<Workspace>> {
        self.create_workspace_with(
            CreateWorkspaceOptions {
                name,
                initial_content: InitialContent::Terminal,
                correlation_key: None,
            },
            MutationOptions::unique()?,
        )
    }

    pub fn create_empty_workspace(&self, name: Option<String>) -> Result<Created<Workspace>> {
        self.create_workspace_with(
            CreateWorkspaceOptions {
                name,
                initial_content: InitialContent::Empty,
                correlation_key: None,
            },
            MutationOptions::unique()?,
        )
    }

    pub fn create_workspace_with(
        &self,
        options: CreateWorkspaceOptions,
        mutation: MutationOptions,
    ) -> Result<Created<Workspace>> {
        let value = self.client.mutate(
            ops::WORKSPACE_CREATE,
            self.params().extend(wire::create_workspace(options)?),
            mutation,
        )?;
        created(value, |path| Ok(self.workspace(path.workspace_id().clone())))
    }

    pub fn terminal(&self, selector: impl Into<Selector<TerminalId>>) -> Terminal {
        let selector = selector.into();
        Terminal {
            session: self.clone(),
            path: StructuralPath::for_nested_selector(&selector),
            selector,
        }
    }

    pub fn browser(&self, selector: impl Into<Selector<BrowserId>>) -> Browser {
        let selector = selector.into();
        Browser {
            session: self.clone(),
            path: StructuralPath::for_nested_selector(&selector),
            selector,
        }
    }

    fn terminal_from_path(&self, path: &CreatedPath, id: TerminalId) -> Terminal {
        Terminal {
            session: self.clone(),
            path: StructuralPath::from_created(path),
            selector: Selector::id(id),
        }
    }

    fn browser_from_path(&self, path: &CreatedPath, id: BrowserId) -> Browser {
        Browser {
            session: self.clone(),
            path: StructuralPath::from_created(path),
            selector: Selector::id(id),
        }
    }
}

#[derive(Clone, Debug, Default)]
struct StructuralPath {
    workspace: Option<Selector<WorkspaceId>>,
    screen: Option<Selector<ScreenId>>,
    pane: Option<Selector<PaneId>>,
    tab: Option<Selector<TabId>>,
}

impl StructuralPath {
    fn for_nested_selector<I>(selector: &Selector<I>) -> Self {
        match selector {
            Selector::Id(_) => Self::default(),
            Selector::Current(_) | Selector::Name(_) => Self {
                workspace: Some(Selector::current()),
                screen: Some(Selector::current()),
                pane: Some(Selector::current()),
                tab: Some(Selector::current()),
            },
        }
    }

    fn from_created(path: &CreatedPath) -> Self {
        Self {
            workspace: Some(Selector::id(path.workspace_id().clone())),
            screen: path.screen_id().cloned().map(Selector::id),
            pane: path.pane_id().cloned().map(Selector::id),
            tab: path.tab_id().cloned().map(Selector::id),
        }
    }

    fn params(&self) -> Params {
        Params::new()
            .optional_selector(field::WORKSPACE, self.workspace.as_ref())
            .optional_selector(field::SCREEN, self.screen.as_ref())
            .optional_selector(field::PANE, self.pane.as_ref())
            .optional_selector(field::TAB, self.tab.as_ref())
    }
}

#[derive(Clone, Debug)]
pub struct Workspace {
    session: Session,
    selector: Selector<WorkspaceId>,
}

impl Workspace {
    pub fn selector(&self) -> &Selector<WorkspaceId> {
        &self.selector
    }

    pub fn id(&self) -> Option<&WorkspaceId> {
        match &self.selector {
            Selector::Id(id) => Some(id),
            Selector::Current(_) | Selector::Name(_) => None,
        }
    }

    pub fn session(&self) -> &Session {
        &self.session
    }

    fn params(&self) -> Params {
        self.session.params().selector(field::WORKSPACE, &self.selector)
    }

    pub fn refresh(&self) -> Result<WorkspaceSnapshot> {
        wire::snapshot(&self.session.client.read(ops::WORKSPACE_GET, self.params())?, "workspace")
    }

    /// Workspace names are required strings. Empty is a valid exact name.
    pub fn rename(&self, name: impl Into<String>) -> Result<MutationResult<WorkspaceSnapshot>> {
        self.rename_with(name, MutationOptions::unique()?)
    }

    pub fn rename_with(
        &self,
        name: impl Into<String>,
        mutation: MutationOptions,
    ) -> Result<MutationResult<WorkspaceSnapshot>> {
        mutation_snapshot(
            self.session.client.mutate(
                ops::WORKSPACE_RENAME,
                self.params().string(field::NAME, name),
                mutation,
            )?,
            "workspace",
        )
    }

    pub fn move_to(&self, index: u32) -> Result<MutationResult<WorkspaceSnapshot>> {
        self.move_to_with(index, MutationOptions::unique()?)
    }

    pub fn move_to_with(
        &self,
        index: u32,
        mutation: MutationOptions,
    ) -> Result<MutationResult<WorkspaceSnapshot>> {
        mutation_snapshot(
            self.session.client.mutate(
                ops::WORKSPACE_MOVE,
                self.params().u32(field::INDEX, index),
                mutation,
            )?,
            "workspace",
        )
    }

    pub fn focus(&self) -> Result<MutationResult<WorkspaceSnapshot>> {
        self.focus_with(MutationOptions::unique()?)
    }

    pub fn focus_with(
        &self,
        mutation: MutationOptions,
    ) -> Result<MutationResult<WorkspaceSnapshot>> {
        mutation_snapshot(
            self.session.client.mutate(ops::WORKSPACE_FOCUS, self.params(), mutation)?,
            "workspace",
        )
    }

    pub fn close(&self) -> Result<MutationReceipt> {
        self.close_with(MutationOptions::unique()?)
    }

    pub fn close_with(&self, mutation: MutationOptions) -> Result<MutationReceipt> {
        mutation_empty(self.session.client.mutate(ops::WORKSPACE_CLOSE, self.params(), mutation)?)
    }

    pub fn run(&self, command: RunCommand) -> Result<Created<Terminal>> {
        self.run_with(RunOptions::command(command), MutationOptions::unique()?)
    }

    pub fn run_with(
        &self,
        options: RunOptions,
        mutation: MutationOptions,
    ) -> Result<Created<Terminal>> {
        let value = self.session.client.mutate(
            ops::WORKSPACE_RUN,
            self.params().extend(wire::run(options)?),
            mutation,
        )?;
        created(value, |path| {
            Ok(self.session.terminal_from_path(
                path,
                path.terminal_id().cloned().ok_or_else(|| {
                    Error::UnexpectedEnvelope("created terminal path lacks terminal_id".to_string())
                })?,
            ))
        })
    }

    pub fn apply_layout(
        &self,
        options: LayoutOptions,
    ) -> Result<MutationResult<WorkspaceSnapshot>> {
        self.apply_layout_with(options, MutationOptions::unique()?)
    }

    pub fn apply_layout_with(
        &self,
        options: LayoutOptions,
        mutation: MutationOptions,
    ) -> Result<MutationResult<WorkspaceSnapshot>> {
        let document = wire::layout_document(options.document)?;
        mutation_snapshot(
            self.session.client.mutate(
                ops::WORKSPACE_LAYOUT_APPLY,
                self.params().value(field::LAYOUT, document),
                mutation,
            )?,
            "workspace",
        )
    }

    pub fn screen(&self, selector: impl Into<Selector<ScreenId>>) -> Screen {
        Screen { workspace: self.clone(), selector: selector.into() }
    }

    pub fn current_screen(&self) -> Screen {
        self.screen(Selector::current())
    }

    pub fn screens(&self) -> Result<Vec<Screen>> {
        wire::list::<ScreenSnapshot>(
            &self.session.client.read(ops::SCREEN_LIST, self.params())?,
            "screens",
            "screen",
        )
        .map(|snapshots| snapshots.into_iter().map(|snapshot| self.screen(snapshot.id)).collect())
    }

    pub fn find_screens_by_name(&self, name: &str) -> Result<Vec<Screen>> {
        Ok(wire::list::<ScreenSnapshot>(
            &self.session.client.read(ops::SCREEN_LIST, self.params())?,
            "screens",
            "screen",
        )?
        .into_iter()
        .filter(|snapshot| snapshot.name.as_deref() == Some(name))
        .map(|snapshot| self.screen(snapshot.id))
        .collect())
    }

    pub fn create_screen(&self, options: CreateScreenOptions) -> Result<Created<Screen>> {
        self.create_screen_with(options, MutationOptions::unique()?)
    }

    pub fn create_screen_with(
        &self,
        options: CreateScreenOptions,
        mutation: MutationOptions,
    ) -> Result<Created<Screen>> {
        let value = self.session.client.mutate(
            ops::SCREEN_CREATE,
            self.params().extend(wire::create_screen(options)?),
            mutation,
        )?;
        created(value, |path| {
            Ok(self.screen(path.screen_id().cloned().ok_or_else(|| {
                Error::UnexpectedEnvelope("created screen path lacks screen_id".to_string())
            })?))
        })
    }
}

#[derive(Clone, Debug)]
pub struct Screen {
    workspace: Workspace,
    selector: Selector<ScreenId>,
}

impl Screen {
    pub fn selector(&self) -> &Selector<ScreenId> {
        &self.selector
    }

    pub fn id(&self) -> Option<&ScreenId> {
        match &self.selector {
            Selector::Id(id) => Some(id),
            Selector::Current(_) | Selector::Name(_) => None,
        }
    }

    pub fn workspace(&self) -> &Workspace {
        &self.workspace
    }

    fn params(&self) -> Params {
        self.workspace.params().selector(field::SCREEN, &self.selector)
    }

    pub fn refresh(&self) -> Result<ScreenSnapshot> {
        wire::snapshot(
            &self.workspace.session.client.read(ops::SCREEN_GET, self.params())?,
            "screen",
        )
    }

    pub fn rename(&self, name: impl Into<String>) -> Result<MutationResult<ScreenSnapshot>> {
        self.set_name(Some(name.into()))
    }

    pub fn clear_name(&self) -> Result<MutationResult<ScreenSnapshot>> {
        self.set_name(None)
    }

    pub fn set_name(&self, name: Option<String>) -> Result<MutationResult<ScreenSnapshot>> {
        self.set_name_with(LabelOptions { name }, MutationOptions::unique()?)
    }

    pub fn set_name_with(
        &self,
        options: LabelOptions,
        mutation: MutationOptions,
    ) -> Result<MutationResult<ScreenSnapshot>> {
        mutation_snapshot(
            self.workspace.session.client.mutate(
                ops::SCREEN_RENAME,
                self.params().extend(label_params(options)),
                mutation,
            )?,
            "screen",
        )
    }

    pub fn focus(&self) -> Result<MutationResult<ScreenSnapshot>> {
        self.focus_with(MutationOptions::unique()?)
    }

    pub fn focus_with(&self, mutation: MutationOptions) -> Result<MutationResult<ScreenSnapshot>> {
        mutation_snapshot(
            self.workspace.session.client.mutate(ops::SCREEN_FOCUS, self.params(), mutation)?,
            "screen",
        )
    }

    pub fn close(&self) -> Result<MutationReceipt> {
        self.close_with(MutationOptions::unique()?)
    }

    pub fn close_with(&self, mutation: MutationOptions) -> Result<MutationReceipt> {
        mutation_empty(self.workspace.session.client.mutate(
            ops::SCREEN_CLOSE,
            self.params(),
            mutation,
        )?)
    }

    pub fn export_layout(&self) -> Result<LayoutDocument> {
        wire::decode_exact(
            &self.workspace.session.client.read(ops::SCREEN_LAYOUT_EXPORT, self.params())?,
            "layout document",
        )
    }

    pub fn undo_layout(
        &self,
        options: UndoLayoutOptions,
    ) -> Result<MutationResult<ScreenSnapshot>> {
        self.undo_layout_with(options, MutationOptions::unique()?)
    }

    pub fn undo_layout_with(
        &self,
        options: UndoLayoutOptions,
        mutation: MutationOptions,
    ) -> Result<MutationResult<ScreenSnapshot>> {
        options.validate()?;
        mutation_snapshot(
            self.workspace.session.client.mutate(
                ops::SCREEN_LAYOUT_UNDO,
                self.params()
                    .optional_bool(field::CONFIRM_CLOSE, options.confirm_close.then_some(true))
                    .optional_string(field::CONFIRMATION_TOKEN, options.confirmation_token),
                mutation,
            )?,
            "screen",
        )
    }

    pub fn pane(&self, selector: impl Into<Selector<PaneId>>) -> Pane {
        Pane { screen: self.clone(), selector: selector.into() }
    }

    pub fn current_pane(&self) -> Pane {
        self.pane(Selector::current())
    }

    pub fn panes(&self) -> Result<Vec<Pane>> {
        wire::list::<PaneSnapshot>(
            &self.workspace.session.client.read(ops::PANE_LIST, self.params())?,
            "panes",
            "pane",
        )
        .map(|snapshots| snapshots.into_iter().map(|snapshot| self.pane(snapshot.id)).collect())
    }

    pub fn find_panes_by_name(&self, name: &str) -> Result<Vec<Pane>> {
        Ok(wire::list::<PaneSnapshot>(
            &self.workspace.session.client.read(ops::PANE_LIST, self.params())?,
            "panes",
            "pane",
        )?
        .into_iter()
        .filter(|snapshot| snapshot.name.as_deref() == Some(name))
        .map(|snapshot| self.pane(snapshot.id))
        .collect())
    }

    pub fn create_pane(&self, options: CreatePaneOptions) -> Result<Created<Pane>> {
        self.create_pane_with(options, MutationOptions::unique()?)
    }

    pub fn create_pane_with(
        &self,
        options: CreatePaneOptions,
        mutation: MutationOptions,
    ) -> Result<Created<Pane>> {
        let value = self.workspace.session.client.mutate(
            ops::PANE_CREATE,
            self.params().extend(wire::create_pane(options)?),
            mutation,
        )?;
        created(value, |path| {
            Ok(self.pane(path.pane_id().cloned().ok_or_else(|| {
                Error::UnexpectedEnvelope("created pane path lacks pane_id".to_string())
            })?))
        })
    }
}

#[derive(Clone, Debug)]
pub struct Pane {
    screen: Screen,
    selector: Selector<PaneId>,
}

impl Pane {
    pub fn selector(&self) -> &Selector<PaneId> {
        &self.selector
    }

    pub fn id(&self) -> Option<&PaneId> {
        match &self.selector {
            Selector::Id(id) => Some(id),
            Selector::Current(_) | Selector::Name(_) => None,
        }
    }

    pub fn screen(&self) -> &Screen {
        &self.screen
    }

    fn params(&self) -> Params {
        self.screen.params().selector(field::PANE, &self.selector)
    }

    pub fn refresh(&self) -> Result<PaneSnapshot> {
        wire::snapshot(
            &self.screen.workspace.session.client.read(ops::PANE_GET, self.params())?,
            "pane",
        )
    }

    pub fn split(&self, options: SplitOptions) -> Result<Created<Pane>> {
        self.split_with(options, MutationOptions::unique()?)
    }

    pub fn split_with(
        &self,
        options: SplitOptions,
        mutation: MutationOptions,
    ) -> Result<Created<Pane>> {
        let value = self.screen.workspace.session.client.mutate(
            ops::PANE_SPLIT,
            self.params().extend(wire::split(options)?),
            mutation,
        )?;
        created(value, |path| {
            Ok(self.screen.pane(path.pane_id().cloned().ok_or_else(|| {
                Error::UnexpectedEnvelope("split path lacks pane_id".to_string())
            })?))
        })
    }

    pub fn rename(&self, name: impl Into<String>) -> Result<MutationResult<PaneSnapshot>> {
        self.set_name(Some(name.into()))
    }

    pub fn clear_name(&self) -> Result<MutationResult<PaneSnapshot>> {
        self.set_name(None)
    }

    pub fn set_name(&self, name: Option<String>) -> Result<MutationResult<PaneSnapshot>> {
        self.set_name_with(LabelOptions { name }, MutationOptions::unique()?)
    }

    pub fn set_name_with(
        &self,
        options: LabelOptions,
        mutation: MutationOptions,
    ) -> Result<MutationResult<PaneSnapshot>> {
        mutation_snapshot(
            self.screen.workspace.session.client.mutate(
                ops::PANE_RENAME,
                self.params().extend(label_params(options)),
                mutation,
            )?,
            "pane",
        )
    }

    pub fn focus(&self) -> Result<MutationResult<PaneSnapshot>> {
        self.focus_with(MutationOptions::unique()?)
    }

    pub fn focus_with(&self, mutation: MutationOptions) -> Result<MutationResult<PaneSnapshot>> {
        mutation_snapshot(
            self.screen.workspace.session.client.mutate(
                ops::PANE_FOCUS,
                self.params(),
                mutation,
            )?,
            "pane",
        )
    }

    pub fn focus_direction(&self, direction: Direction) -> Result<MutationResult<PaneSnapshot>> {
        self.focus_direction_with(direction, MutationOptions::unique()?)
    }

    pub fn focus_direction_with(
        &self,
        direction: Direction,
        mutation: MutationOptions,
    ) -> Result<MutationResult<PaneSnapshot>> {
        mutation_snapshot(
            self.screen.workspace.session.client.mutate(
                ops::PANE_FOCUS_DIRECTION,
                self.params().string(field::DIRECTION, direction.wire_name()),
                mutation,
            )?,
            "pane",
        )
    }

    pub fn neighbor(&self, direction: Direction) -> Result<Option<Pane>> {
        let value = self.screen.workspace.session.client.read(
            ops::PANE_NEIGHBOR_GET,
            self.params().string(field::DIRECTION, direction.wire_name()),
        )?;
        let result: PaneNeighborResult = wire::decode_exact(&value, "pane neighbor result")?;
        Ok(result.pane.map(|snapshot| self.screen.pane(snapshot.id)))
    }

    pub fn swap(&self, options: PaneSwapOptions) -> Result<MutationResult<PaneSnapshot>> {
        self.swap_with(options, MutationOptions::unique()?)
    }

    pub fn swap_with(
        &self,
        options: PaneSwapOptions,
        mutation: MutationOptions,
    ) -> Result<MutationResult<PaneSnapshot>> {
        mutation_snapshot(
            self.screen.workspace.session.client.mutate(
                ops::PANE_SWAP,
                self.params().extend(wire::pane_swap(options)),
                mutation,
            )?,
            "pane",
        )
    }

    pub fn zoom(&self, options: ZoomOptions) -> Result<MutationResult<PaneSnapshot>> {
        self.zoom_with(options, MutationOptions::unique()?)
    }

    pub fn zoom_with(
        &self,
        options: ZoomOptions,
        mutation: MutationOptions,
    ) -> Result<MutationResult<PaneSnapshot>> {
        mutation_snapshot(
            self.screen.workspace.session.client.mutate(
                ops::PANE_ZOOM,
                self.params().optional_bool(field::ENABLED, options.enabled),
                mutation,
            )?,
            "pane",
        )
    }

    pub fn set_split_ratio(
        &self,
        options: SplitRatioOptions,
    ) -> Result<MutationResult<PaneSnapshot>> {
        self.set_split_ratio_with(options, MutationOptions::unique()?)
    }

    pub fn set_split_ratio_with(
        &self,
        options: SplitRatioOptions,
        mutation: MutationOptions,
    ) -> Result<MutationResult<PaneSnapshot>> {
        wire::validate_ratio(options.ratio)?;
        mutation_snapshot(
            self.screen.workspace.session.client.mutate(
                ops::PANE_SPLIT_RATIO_SET,
                self.params()
                    .id(field::SPLIT_ID, &options.split_id)
                    .f64(field::RATIO, options.ratio),
                mutation,
            )?,
            "pane",
        )
    }

    pub fn set_viewport_width(
        &self,
        options: ViewportWidthOptions,
    ) -> Result<MutationResult<PaneSnapshot>> {
        self.set_viewport_width_with(options, MutationOptions::unique()?)
    }

    pub fn set_viewport_width_with(
        &self,
        options: ViewportWidthOptions,
        mutation: MutationOptions,
    ) -> Result<MutationResult<PaneSnapshot>> {
        if options.columns == 0 {
            return Err(Error::InvalidArgument(
                "viewport width must be greater than zero".to_string(),
            ));
        }
        mutation_snapshot(
            self.screen.workspace.session.client.mutate(
                ops::PANE_VIEWPORT_WIDTH_SET,
                self.params().u16(field::COLUMNS, options.columns),
                mutation,
            )?,
            "pane",
        )
    }

    pub fn close(&self) -> Result<MutationReceipt> {
        self.close_with(MutationOptions::unique()?)
    }

    pub fn close_with(&self, mutation: MutationOptions) -> Result<MutationReceipt> {
        mutation_empty(self.screen.workspace.session.client.mutate(
            ops::PANE_CLOSE,
            self.params(),
            mutation,
        )?)
    }

    pub fn run(&self, command: RunCommand) -> Result<Created<Terminal>> {
        self.run_with(RunOptions::command(command), MutationOptions::unique()?)
    }

    pub fn run_with(
        &self,
        options: RunOptions,
        mutation: MutationOptions,
    ) -> Result<Created<Terminal>> {
        let value = self.screen.workspace.session.client.mutate(
            ops::PANE_RUN,
            self.params().extend(wire::run(options)?),
            mutation,
        )?;
        created(value, |path| {
            Ok(self.screen.workspace.session.terminal_from_path(
                path,
                path.terminal_id().cloned().ok_or_else(|| {
                    Error::UnexpectedEnvelope("created terminal path lacks terminal_id".to_string())
                })?,
            ))
        })
    }

    pub fn create_terminal(&self, options: TerminalCreateOptions) -> Result<Created<Terminal>> {
        self.create_terminal_with(options, MutationOptions::unique()?)
    }

    pub fn create_terminal_with(
        &self,
        options: TerminalCreateOptions,
        mutation: MutationOptions,
    ) -> Result<Created<Terminal>> {
        let value = self.screen.workspace.session.client.mutate(
            ops::TAB_CREATE_TERMINAL,
            self.params().extend(wire::terminal_create(options)?),
            mutation,
        )?;
        created(value, |path| {
            Ok(self.screen.workspace.session.terminal_from_path(
                path,
                path.terminal_id().cloned().ok_or_else(|| {
                    Error::UnexpectedEnvelope("created terminal path lacks terminal_id".to_string())
                })?,
            ))
        })
    }

    pub fn create_browser(&self, options: BrowserCreateOptions) -> Result<Created<Browser>> {
        self.create_browser_with(options, MutationOptions::unique()?)
    }

    pub fn create_browser_with(
        &self,
        options: BrowserCreateOptions,
        mutation: MutationOptions,
    ) -> Result<Created<Browser>> {
        let value = self.screen.workspace.session.client.mutate(
            ops::TAB_CREATE_BROWSER,
            self.params().extend(wire::browser_create(options)?),
            mutation,
        )?;
        created(value, |path| {
            Ok(self.screen.workspace.session.browser_from_path(
                path,
                path.browser_id().cloned().ok_or_else(|| {
                    Error::UnexpectedEnvelope("created browser path lacks browser_id".to_string())
                })?,
            ))
        })
    }

    pub fn tab(&self, selector: impl Into<Selector<TabId>>) -> Tab {
        Tab { pane: self.clone(), selector: selector.into() }
    }

    pub fn current_tab(&self) -> Tab {
        self.tab(Selector::current())
    }

    pub fn tabs(&self) -> Result<Vec<Tab>> {
        wire::list::<TabSnapshot>(
            &self.screen.workspace.session.client.read(ops::TAB_LIST, self.params())?,
            "tabs",
            "tab",
        )
        .map(|snapshots| snapshots.into_iter().map(|snapshot| self.tab(snapshot.id)).collect())
    }

    pub fn find_tabs_by_name(&self, name: &str) -> Result<Vec<Tab>> {
        Ok(wire::list::<TabSnapshot>(
            &self.screen.workspace.session.client.read(ops::TAB_LIST, self.params())?,
            "tabs",
            "tab",
        )?
        .into_iter()
        .filter(|snapshot| snapshot.name.as_deref() == Some(name))
        .map(|snapshot| self.tab(snapshot.id))
        .collect())
    }
}

#[derive(Clone, Debug)]
pub struct Tab {
    pane: Pane,
    selector: Selector<TabId>,
}

impl Tab {
    pub fn selector(&self) -> &Selector<TabId> {
        &self.selector
    }

    pub fn id(&self) -> Option<&TabId> {
        match &self.selector {
            Selector::Id(id) => Some(id),
            Selector::Current(_) | Selector::Name(_) => None,
        }
    }

    pub fn pane(&self) -> &Pane {
        &self.pane
    }

    fn params(&self) -> Params {
        self.pane.params().selector(field::TAB, &self.selector)
    }

    pub fn refresh(&self) -> Result<TabSnapshot> {
        wire::snapshot(
            &self.pane.screen.workspace.session.client.read(ops::TAB_GET, self.params())?,
            "tab",
        )
    }

    pub fn rename(&self, name: impl Into<String>) -> Result<MutationResult<TabSnapshot>> {
        self.set_name(Some(name.into()))
    }

    pub fn clear_name(&self) -> Result<MutationResult<TabSnapshot>> {
        self.set_name(None)
    }

    pub fn set_name(&self, name: Option<String>) -> Result<MutationResult<TabSnapshot>> {
        self.set_name_with(LabelOptions { name }, MutationOptions::unique()?)
    }

    pub fn set_name_with(
        &self,
        options: LabelOptions,
        mutation: MutationOptions,
    ) -> Result<MutationResult<TabSnapshot>> {
        mutation_snapshot(
            self.pane.screen.workspace.session.client.mutate(
                ops::TAB_RENAME,
                self.params().extend(label_params(options)),
                mutation,
            )?,
            "tab",
        )
    }

    pub fn move_to(&self, options: MoveDestination) -> Result<MutationResult<TabSnapshot>> {
        self.move_to_with(options, MutationOptions::unique()?)
    }

    pub fn move_to_with(
        &self,
        options: MoveDestination,
        mutation: MutationOptions,
    ) -> Result<MutationResult<TabSnapshot>> {
        mutation_snapshot(
            self.pane.screen.workspace.session.client.mutate(
                ops::TAB_MOVE,
                self.params().extend(wire::move_destination(options)),
                mutation,
            )?,
            "tab",
        )
    }

    pub fn focus(&self) -> Result<MutationResult<TabSnapshot>> {
        self.focus_with(MutationOptions::unique()?)
    }

    pub fn focus_with(&self, mutation: MutationOptions) -> Result<MutationResult<TabSnapshot>> {
        mutation_snapshot(
            self.pane.screen.workspace.session.client.mutate(
                ops::TAB_FOCUS,
                self.params(),
                mutation,
            )?,
            "tab",
        )
    }

    pub fn close(&self) -> Result<MutationReceipt> {
        self.close_with(MutationOptions::unique()?)
    }

    pub fn close_with(&self, mutation: MutationOptions) -> Result<MutationReceipt> {
        mutation_empty(self.pane.screen.workspace.session.client.mutate(
            ops::TAB_CLOSE,
            self.params(),
            mutation,
        )?)
    }
}

impl Session {
    pub fn terminals(&self) -> Result<Vec<Terminal>> {
        wire::list::<TerminalSnapshot>(
            &self.client.read(ops::TERMINAL_LIST, self.params())?,
            "terminals",
            "terminal",
        )
        .map(|snapshots| snapshots.into_iter().map(|snapshot| self.terminal(snapshot.id)).collect())
    }

    pub fn find_terminals_by_name(&self, name: &str) -> Result<Vec<Terminal>> {
        Ok(wire::list::<TerminalSnapshot>(
            &self.client.read(ops::TERMINAL_LIST, self.params())?,
            "terminals",
            "terminal",
        )?
        .into_iter()
        .filter(|snapshot| snapshot.title == name)
        .map(|snapshot| self.terminal(snapshot.id))
        .collect())
    }

    pub fn browsers(&self) -> Result<Vec<Browser>> {
        wire::list::<BrowserSnapshot>(
            &self.client.read(ops::BROWSER_LIST, self.params())?,
            "browsers",
            "browser",
        )
        .map(|snapshots| snapshots.into_iter().map(|snapshot| self.browser(snapshot.id)).collect())
    }

    pub fn find_browsers_by_name(&self, name: &str) -> Result<Vec<Browser>> {
        Ok(wire::list::<BrowserSnapshot>(
            &self.client.read(ops::BROWSER_LIST, self.params())?,
            "browsers",
            "browser",
        )?
        .into_iter()
        .filter(|snapshot| snapshot.title == name)
        .map(|snapshot| self.browser(snapshot.id))
        .collect())
    }
}

#[derive(Clone, Debug)]
pub struct Terminal {
    session: Session,
    path: StructuralPath,
    selector: Selector<TerminalId>,
}

impl Terminal {
    pub fn selector(&self) -> &Selector<TerminalId> {
        &self.selector
    }

    pub fn id(&self) -> Option<&TerminalId> {
        match &self.selector {
            Selector::Id(id) => Some(id),
            Selector::Current(_) | Selector::Name(_) => None,
        }
    }

    pub fn session(&self) -> &Session {
        &self.session
    }

    fn params(&self) -> Params {
        self.session.params().extend(self.path.params()).selector(field::TERMINAL, &self.selector)
    }

    pub fn refresh(&self) -> Result<TerminalSnapshot> {
        wire::snapshot(&self.session.client.read(ops::TERMINAL_GET, self.params())?, "terminal")
    }

    pub fn write_text(&self, text: impl Into<String>) -> Result<MutationReceipt> {
        self.write_text_with(text, MutationOptions::unique()?)
    }

    pub fn write_text_with(
        &self,
        text: impl Into<String>,
        mutation: MutationOptions,
    ) -> Result<MutationReceipt> {
        mutation_empty(self.session.client.mutate(
            ops::TERMINAL_INPUT_WRITE,
            self.params().string(field::TEXT, text),
            mutation,
        )?)
    }

    pub fn write_bytes(&self, bytes: &[u8]) -> Result<MutationReceipt> {
        self.write_bytes_with(bytes, MutationOptions::unique()?)
    }

    pub fn write_bytes_with(
        &self,
        bytes: &[u8],
        mutation: MutationOptions,
    ) -> Result<MutationReceipt> {
        mutation_empty(self.session.client.mutate(
            ops::TERMINAL_INPUT_WRITE,
            self.params().string(
                field::BYTES_BASE64,
                base64::engine::general_purpose::STANDARD.encode(bytes),
            ),
            mutation,
        )?)
    }

    pub fn keys(&self, options: TerminalKeysOptions) -> Result<MutationReceipt> {
        self.keys_with(options, MutationOptions::unique()?)
    }

    pub fn keys_with(
        &self,
        options: TerminalKeysOptions,
        mutation: MutationOptions,
    ) -> Result<MutationReceipt> {
        if options.keys.is_empty() {
            return Err(Error::InvalidArgument(
                "terminal keys must contain at least one key".to_string(),
            ));
        }
        mutation_empty(self.session.client.mutate(
            ops::TERMINAL_INPUT_KEYS,
            self.params().value(
                field::KEYS,
                Value::Array(options.keys.into_iter().map(Value::String).collect()),
            ),
            mutation,
        )?)
    }

    pub fn mouse(&self, options: TerminalMouseOptions) -> Result<MutationReceipt> {
        self.mouse_with(options, MutationOptions::unique()?)
    }

    pub fn mouse_with(
        &self,
        options: TerminalMouseOptions,
        mutation: MutationOptions,
    ) -> Result<MutationReceipt> {
        mutation_empty(self.session.client.mutate(
            ops::TERMINAL_INPUT_MOUSE,
            self.params().extend(wire::terminal_mouse(options)?),
            mutation,
        )?)
    }

    pub fn input_focus(&self, options: FocusInputOptions) -> Result<MutationReceipt> {
        self.input_focus_with(options, MutationOptions::unique()?)
    }

    pub fn input_focus_with(
        &self,
        options: FocusInputOptions,
        mutation: MutationOptions,
    ) -> Result<MutationReceipt> {
        mutation_empty(self.session.client.mutate(
            ops::TERMINAL_INPUT_FOCUS,
            self.params().boolean(field::FOCUSED, options.focused),
            mutation,
        )?)
    }

    pub fn read_screen(&self, _options: ReadScreenOptions) -> Result<TerminalScreenResult> {
        wire::decode_exact(
            &self.session.client.read(ops::TERMINAL_SCREEN_READ, self.params())?,
            "terminal screen result",
        )
    }

    pub fn read_state(&self) -> Result<TerminalStateResult> {
        wire::decode_exact(
            &self.session.client.read(ops::TERMINAL_STATE_READ, self.params())?,
            "terminal state result",
        )
    }

    pub fn read_history(&self, options: ReadHistoryOptions) -> Result<TerminalHistoryResult> {
        if options.limit.is_some_and(|limit| limit == 0 || limit > 10_000) {
            return Err(Error::InvalidArgument(
                "history limit must be between 1 and 10000".to_string(),
            ));
        }
        let value = self.session.client.read(
            ops::TERMINAL_HISTORY_READ,
            self.params()
                .optional_u64(field::BEFORE, options.before)
                .optional_u32(field::LIMIT, options.limit)
                .optional_bool(field::STYLED, options.styled),
        )?;
        wire::terminal_history(&value)
    }

    pub fn clear_history(&self) -> Result<MutationReceipt> {
        self.clear_history_with(MutationOptions::unique()?)
    }

    pub fn clear_history_with(&self, mutation: MutationOptions) -> Result<MutationReceipt> {
        mutation_empty(self.session.client.mutate(
            ops::TERMINAL_HISTORY_CLEAR,
            self.params(),
            mutation,
        )?)
    }

    pub fn wait(&self, options: WaitOptions) -> Result<TerminalWaitResult> {
        if options.pattern.is_empty() {
            return Err(Error::InvalidArgument("wait pattern must not be empty".to_string()));
        }
        let value = self.session.client.read(
            ops::TERMINAL_WAIT,
            self.params()
                .string(field::PATTERN, options.pattern)
                .optional_u64(field::TIMEOUT_MS, options.timeout_ms),
        )?;
        wire::decode_exact(&value, "terminal wait result")
    }

    pub fn wait_exit(&self, timeout_ms: Option<u64>) -> Result<TerminalWaitExitResult> {
        wire::decode_exact(
            &self.session.client.read(
                ops::TERMINAL_WAIT_EXIT,
                self.params().optional_u64(field::TIMEOUT_MS, timeout_ms),
            )?,
            "terminal wait exit result",
        )
    }

    pub fn copy(&self, options: CopyOptions) -> Result<TerminalCopyResult> {
        let params = match options.mode {
            Some(mode) => self.params().string(field::MODE, mode.wire_name()),
            None => self.params(),
        };
        wire::decode_exact(
            &self.session.client.read(ops::TERMINAL_COPY, params)?,
            "terminal copy result",
        )
    }

    pub fn process(&self) -> Result<ProcessInfoResult> {
        wire::decode_exact(
            &self.session.client.read(ops::TERMINAL_PROCESS_GET, self.params())?,
            "terminal process result",
        )
    }

    pub fn viewer_resize(
        &self,
        attachment_lease: &str,
        options: Size,
    ) -> Result<ViewerResizeResult> {
        wire::validate_size(options)?;
        wire::decode_exact(
            &self.session.client.connection_control(
                ops::TERMINAL_VIEWER_RESIZE,
                self.params()
                    .string(field::ATTACHMENT_LEASE, attachment_lease)
                    .u16(field::COLS, options.cols)
                    .u16(field::ROWS, options.rows),
            )?,
            "terminal viewer resize result",
        )
    }

    pub fn viewer_release(&self, attachment_lease: &str) -> Result<ViewerReleaseResult> {
        wire::decode_exact(
            &self.session.client.connection_control(
                ops::TERMINAL_VIEWER_RELEASE,
                self.params().string(field::ATTACHMENT_LEASE, attachment_lease),
            )?,
            "terminal viewer release result",
        )
    }

    pub fn scroll(&self, options: ScrollOptions) -> Result<MutationReceipt> {
        self.scroll_with(options, MutationOptions::unique()?)
    }

    pub fn scroll_with(
        &self,
        options: ScrollOptions,
        mutation: MutationOptions,
    ) -> Result<MutationReceipt> {
        mutation_empty(self.session.client.mutate(
            ops::TERMINAL_VIEWPORT_SCROLL,
            self.params().i32(field::DELTA_ROWS, options.delta_rows),
            mutation,
        )?)
    }

    pub fn move_to(&self, options: MoveDestination) -> Result<MutationResult<TerminalSnapshot>> {
        self.move_to_with(options, MutationOptions::unique()?)
    }

    pub fn move_to_with(
        &self,
        options: MoveDestination,
        mutation: MutationOptions,
    ) -> Result<MutationResult<TerminalSnapshot>> {
        mutation_snapshot(
            self.session.client.mutate(
                ops::TERMINAL_MOVE,
                self.params().extend(wire::move_destination(options)),
                mutation,
            )?,
            "terminal",
        )
    }

    pub fn project(&self, options: TerminalProjectOptions) -> Result<MutationResult<TabSnapshot>> {
        self.project_with(options, MutationOptions::unique()?)
    }

    pub fn project_with(
        &self,
        options: TerminalProjectOptions,
        mutation: MutationOptions,
    ) -> Result<MutationResult<TabSnapshot>> {
        mutation_snapshot(
            self.session.client.mutate(
                ops::TERMINAL_PROJECT,
                self.params().extend(wire::terminal_project(options)),
                mutation,
            )?,
            "tab",
        )
    }

    pub fn attach(&self, options: TerminalAttachOptions) -> Result<TerminalAttachment> {
        self.session
            .client
            .stream(ops::TERMINAL_ATTACH, self.params().extend(wire::terminal_attach(options)?))
            .map(TerminalAttachment::new)
    }

    pub fn create_renderer_grant(&self, options: RendererGrantOptions) -> Result<RendererGrant> {
        if options.ttl_ms.is_some_and(|ttl| ttl == 0 || ttl > 60_000) {
            return Err(Error::InvalidArgument(
                "renderer grant ttl_ms must be between 1 and 60000".to_string(),
            ));
        }
        let value = self.session.client.connection_control(
            ops::TERMINAL_RENDERER_GRANT_CREATE,
            self.params().optional_u32(field::TTL_MS, options.ttl_ms),
        )?;
        let object = value.as_object().ok_or_else(|| {
            Error::UnexpectedEnvelope("renderer grant must be an object".to_string())
        })?;
        let unknown = object
            .keys()
            .filter(|key| {
                !matches!(key.as_str(), "token" | "endpoint" | "terminal_id" | "rights" | "ttl_ms")
            })
            .cloned()
            .collect::<Vec<_>>();
        if !unknown.is_empty() {
            return Err(Error::UnexpectedEnvelope(format!(
                "renderer grant contains unknown fields: {}",
                unknown.join(", ")
            )));
        }
        let token = object
            .get("token")
            .and_then(Value::as_str)
            .ok_or_else(|| {
                Error::UnexpectedEnvelope("renderer grant token is required".to_string())
            })?
            .to_string();
        if token.is_empty() {
            return Err(Error::UnexpectedEnvelope(
                "renderer grant token must not be empty".to_string(),
            ));
        }
        let endpoint = object
            .get("endpoint")
            .and_then(Value::as_str)
            .ok_or_else(|| {
                Error::UnexpectedEnvelope("renderer grant endpoint is required".to_string())
            })?
            .to_string();
        let terminal_id = object
            .get("terminal_id")
            .and_then(Value::as_str)
            .ok_or_else(|| {
                Error::UnexpectedEnvelope("renderer grant terminal_id is required".to_string())
            })
            .and_then(|value| TerminalId::parse(value.to_string()))?;
        let rights = object
            .get("rights")
            .and_then(Value::as_array)
            .ok_or_else(|| {
                Error::UnexpectedEnvelope("renderer grant rights are required".to_string())
            })?
            .iter()
            .map(|value| {
                value.as_str().map(ToOwned::to_owned).ok_or_else(|| {
                    Error::UnexpectedEnvelope("renderer grant rights must be strings".to_string())
                })
            })
            .collect::<Result<Vec<_>>>()?;
        if rights.is_empty() {
            return Err(Error::UnexpectedEnvelope(
                "renderer grant rights must not be empty".to_string(),
            ));
        }
        let ttl_ms = object
            .get("ttl_ms")
            .and_then(Value::as_u64)
            .and_then(|value| u32::try_from(value).ok())
            .ok_or_else(|| {
                Error::UnexpectedEnvelope("renderer grant ttl_ms is required".to_string())
            })?;
        if ttl_ms == 0 || ttl_ms > 60_000 {
            return Err(Error::UnexpectedEnvelope(
                "renderer grant ttl_ms must be between 1 and 60000".to_string(),
            ));
        }
        RendererGrant::new(token, endpoint, terminal_id, rights, ttl_ms)
            .map_err(|error| Error::UnexpectedEnvelope(format!("invalid renderer grant: {error}")))
    }

    pub fn close(&self) -> Result<MutationReceipt> {
        self.close_with(MutationOptions::unique()?)
    }

    pub fn close_with(&self, mutation: MutationOptions) -> Result<MutationReceipt> {
        mutation_empty(self.session.client.mutate(ops::TERMINAL_CLOSE, self.params(), mutation)?)
    }
}

#[derive(Clone, Debug)]
pub struct Browser {
    session: Session,
    path: StructuralPath,
    selector: Selector<BrowserId>,
}

impl Browser {
    pub fn selector(&self) -> &Selector<BrowserId> {
        &self.selector
    }

    pub fn id(&self) -> Option<&BrowserId> {
        match &self.selector {
            Selector::Id(id) => Some(id),
            Selector::Current(_) | Selector::Name(_) => None,
        }
    }

    pub fn session(&self) -> &Session {
        &self.session
    }

    fn params(&self) -> Params {
        self.session.params().extend(self.path.params()).selector(field::BROWSER, &self.selector)
    }

    pub fn refresh(&self) -> Result<BrowserSnapshot> {
        wire::snapshot(&self.session.client.read(ops::BROWSER_GET, self.params())?, "browser")
    }

    pub fn navigate(&self, options: NavigateOptions) -> Result<MutationResult<BrowserSnapshot>> {
        self.navigate_with(options, MutationOptions::unique()?)
    }

    pub fn navigate_with(
        &self,
        options: NavigateOptions,
        mutation: MutationOptions,
    ) -> Result<MutationResult<BrowserSnapshot>> {
        if options.url.is_empty() {
            return Err(Error::InvalidArgument("browser URL must not be empty".to_string()));
        }
        mutation_snapshot(
            self.session.client.mutate(
                ops::BROWSER_NAVIGATE,
                self.params().string(field::URL, options.url),
                mutation,
            )?,
            "browser",
        )
    }

    pub fn back(&self) -> Result<MutationResult<BrowserSnapshot>> {
        self.back_with(MutationOptions::unique()?)
    }

    pub fn back_with(&self, mutation: MutationOptions) -> Result<MutationResult<BrowserSnapshot>> {
        mutation_snapshot(
            self.session.client.mutate(ops::BROWSER_BACK, self.params(), mutation)?,
            "browser",
        )
    }

    pub fn forward(&self) -> Result<MutationResult<BrowserSnapshot>> {
        self.forward_with(MutationOptions::unique()?)
    }

    pub fn forward_with(
        &self,
        mutation: MutationOptions,
    ) -> Result<MutationResult<BrowserSnapshot>> {
        mutation_snapshot(
            self.session.client.mutate(ops::BROWSER_FORWARD, self.params(), mutation)?,
            "browser",
        )
    }

    pub fn reload(&self) -> Result<MutationResult<BrowserSnapshot>> {
        self.reload_with(MutationOptions::unique()?)
    }

    pub fn reload_with(
        &self,
        mutation: MutationOptions,
    ) -> Result<MutationResult<BrowserSnapshot>> {
        mutation_snapshot(
            self.session.client.mutate(ops::BROWSER_RELOAD, self.params(), mutation)?,
            "browser",
        )
    }

    pub fn activate(&self) -> Result<MutationResult<BrowserSnapshot>> {
        self.activate_with(MutationOptions::unique()?)
    }

    pub fn activate_with(
        &self,
        mutation: MutationOptions,
    ) -> Result<MutationResult<BrowserSnapshot>> {
        mutation_snapshot(
            self.session.client.mutate(ops::BROWSER_ACTIVATE, self.params(), mutation)?,
            "browser",
        )
    }

    pub fn key(&self, options: BrowserKeyOptions) -> Result<MutationReceipt> {
        self.key_with(options, MutationOptions::unique()?)
    }

    pub fn key_with(
        &self,
        options: BrowserKeyOptions,
        mutation: MutationOptions,
    ) -> Result<MutationReceipt> {
        mutation_empty(self.session.client.mutate(
            ops::BROWSER_INPUT_KEY,
            self.params().extend(wire::browser_key(options)?),
            mutation,
        )?)
    }

    pub fn text(&self, options: TextInputOptions) -> Result<MutationReceipt> {
        self.text_with(options, MutationOptions::unique()?)
    }

    pub fn text_with(
        &self,
        options: TextInputOptions,
        mutation: MutationOptions,
    ) -> Result<MutationReceipt> {
        mutation_empty(self.session.client.mutate(
            ops::BROWSER_INPUT_TEXT,
            self.params().string(field::TEXT, options.text),
            mutation,
        )?)
    }

    pub fn mouse(&self, options: BrowserMouseOptions) -> Result<MutationReceipt> {
        self.mouse_with(options, MutationOptions::unique()?)
    }

    pub fn mouse_with(
        &self,
        options: BrowserMouseOptions,
        mutation: MutationOptions,
    ) -> Result<MutationReceipt> {
        mutation_empty(self.session.client.mutate(
            ops::BROWSER_INPUT_MOUSE,
            self.params().extend(wire::browser_mouse(options)?),
            mutation,
        )?)
    }

    pub fn wheel(&self, options: WheelOptions) -> Result<MutationReceipt> {
        self.wheel_with(options, MutationOptions::unique()?)
    }

    pub fn wheel_with(
        &self,
        options: WheelOptions,
        mutation: MutationOptions,
    ) -> Result<MutationReceipt> {
        mutation_empty(self.session.client.mutate(
            ops::BROWSER_INPUT_WHEEL,
            self.params().extend(wire::wheel(options)?),
            mutation,
        )?)
    }

    pub fn viewer_resize(
        &self,
        attachment_lease: &str,
        options: PixelSize,
    ) -> Result<BrowserViewerResizeResult> {
        wire::validate_pixel_size(options)?;
        wire::decode_exact(
            &self.session.client.connection_control(
                ops::BROWSER_VIEWER_RESIZE,
                self.params()
                    .string(field::ATTACHMENT_LEASE, attachment_lease)
                    .u32(field::WIDTH_PX, options.width_px)
                    .u32(field::HEIGHT_PX, options.height_px),
            )?,
            "browser viewer resize result",
        )
    }

    pub fn viewer_release(&self, attachment_lease: &str) -> Result<ViewerReleaseResult> {
        wire::decode_exact(
            &self.session.client.connection_control(
                ops::BROWSER_VIEWER_RELEASE,
                self.params().string(field::ATTACHMENT_LEASE, attachment_lease),
            )?,
            "browser viewer release result",
        )
    }

    pub fn attach(&self, options: BrowserAttachOptions) -> Result<BrowserAttachment> {
        self.session
            .client
            .stream(ops::BROWSER_ATTACH, self.params().extend(wire::browser_attach(options)?))
            .map(BrowserAttachment::new)
    }

    pub fn close(&self) -> Result<MutationReceipt> {
        self.close_with(MutationOptions::unique()?)
    }

    pub fn close_with(&self, mutation: MutationOptions) -> Result<MutationReceipt> {
        mutation_empty(self.session.client.mutate(ops::BROWSER_CLOSE, self.params(), mutation)?)
    }
}

impl Session {
    pub fn connected_client(
        &self,
        selector: impl Into<Selector<ConnectedClientId>>,
    ) -> ConnectedClient {
        ConnectedClient { session: self.clone(), selector: selector.into() }
    }

    pub fn connected_clients(&self) -> Result<Vec<ConnectedClient>> {
        wire::list::<ClientSnapshot>(
            &self.client.read(ops::CLIENT_LIST, self.params())?,
            "clients",
            "client",
        )
        .map(|snapshots| {
            snapshots.into_iter().map(|snapshot| self.connected_client(snapshot.id)).collect()
        })
    }

    pub fn pairing_request(
        &self,
        selector: impl Into<Selector<PairingRequestId>>,
    ) -> PairingRequest {
        PairingRequest { session: self.clone(), selector: selector.into() }
    }

    pub fn pairing_requests(&self) -> Result<Vec<PairingRequest>> {
        wire::list::<PairingRequestSnapshot>(
            &self.client.read(ops::PAIRING_REQUEST_LIST, self.params())?,
            "pairing_requests",
            "pairing_request",
        )
        .map(|snapshots| {
            snapshots.into_iter().map(|snapshot| self.pairing_request(snapshot.id)).collect()
        })
    }

    pub fn frontend_projection(
        &self,
        selector: impl Into<Selector<FrontendProjectionId>>,
    ) -> FrontendProjection {
        FrontendProjection { session: self.clone(), selector: selector.into() }
    }

    pub fn current_frontend_projection(&self) -> FrontendProjection {
        self.frontend_projection(Selector::current())
    }

    pub fn notification(&self, selector: impl Into<Selector<NotificationId>>) -> Notification {
        Notification { session: self.clone(), selector: selector.into() }
    }

    pub fn notifications(&self, options: NotificationListOptions) -> Result<Vec<Notification>> {
        if options.limit.is_some_and(|limit| limit == 0 || limit > 1_000) {
            return Err(Error::InvalidArgument(
                "notification limit must be between 1 and 1000".to_string(),
            ));
        }
        wire::list::<NotificationSnapshot>(
            &self.client.read(
                ops::NOTIFICATION_LIST,
                self.params().optional_u32(field::LIMIT, options.limit),
            )?,
            "notifications",
            "notification",
        )
        .map(|snapshots| {
            snapshots.into_iter().map(|snapshot| self.notification(snapshot.id)).collect()
        })
    }

    pub fn create_notification(
        &self,
        options: NotificationOptions,
    ) -> Result<MutationResult<NotificationSnapshot>> {
        self.create_notification_with(options, MutationOptions::unique()?)
    }

    pub fn create_notification_with(
        &self,
        options: NotificationOptions,
        mutation: MutationOptions,
    ) -> Result<MutationResult<NotificationSnapshot>> {
        if options.title.is_empty() {
            return Err(Error::InvalidArgument("notification title must not be empty".to_string()));
        }
        let value = self.client.mutate(
            ops::NOTIFICATION_CREATE,
            self.params()
                .string(field::TITLE, options.title)
                .string(field::BODY, options.body)
                .optional_string(
                    field::LEVEL,
                    options.level.map(|level| level.wire_name().to_string()),
                )
                .optional_id(field::TERMINAL_ID, options.terminal_id.as_ref()),
            mutation,
        )?;
        mutation_snapshot(value, "notification")
    }

    pub fn agent(&self, selector: impl Into<Selector<AgentId>>) -> Agent {
        Agent { session: self.clone(), selector: selector.into() }
    }

    pub fn agents(&self, options: AgentListOptions) -> Result<Vec<Agent>> {
        wire::list::<AgentSnapshot>(
            &self.client.read(
                ops::AGENT_LIST,
                self.params()
                    .optional_id(field::TERMINAL_ID, options.terminal_id.as_ref())
                    .optional_string(
                        field::STATE,
                        options.state.map(|state| state.wire_name().to_string()),
                    ),
            )?,
            "agents",
            "agent",
        )
        .map(|snapshots| snapshots.into_iter().map(|snapshot| self.agent(snapshot.id)).collect())
    }

    pub fn report_agent(
        &self,
        options: AgentReportOptions,
    ) -> Result<MutationResult<AgentSnapshot>> {
        self.report_agent_with(options, MutationOptions::unique()?)
    }

    pub fn report_agent_with(
        &self,
        options: AgentReportOptions,
        mutation: MutationOptions,
    ) -> Result<MutationResult<AgentSnapshot>> {
        let value = self.client.mutate(
            ops::AGENT_REPORT,
            self.params()
                .id(field::TERMINAL_ID, &options.terminal_id)
                .string(field::STATE, options.state.wire_name())
                .string(field::SOURCE, options.source.wire_name())
                .optional_string(field::SOURCE_SESSION, options.source_session),
            mutation,
        )?;
        mutation_snapshot(value, "agent")
    }

    pub fn sidebar_view(&self, selector: impl Into<Selector<SidebarViewId>>) -> SidebarView {
        SidebarView { session: self.clone(), selector: selector.into() }
    }

    pub fn current_sidebar_view(&self) -> SidebarView {
        self.sidebar_view(Selector::current())
    }

    pub fn ensure_sidebar_view(
        &self,
        options: SidebarEnsureOptions,
    ) -> Result<MutationResult<SidebarViewSnapshot>> {
        self.ensure_sidebar_view_with(options, MutationOptions::unique()?)
    }

    pub fn ensure_sidebar_view_with(
        &self,
        options: SidebarEnsureOptions,
        mutation: MutationOptions,
    ) -> Result<MutationResult<SidebarViewSnapshot>> {
        wire::validate_size(options.size)?;
        let params = self
            .params()
            .u16(field::COLS, options.size.cols)
            .u16(field::ROWS, options.size.rows)
            .optional_bool(field::RELAUNCH, options.relaunch);
        let value = self.client.mutate(ops::SIDEBAR_VIEW_ENSURE, params, mutation)?;
        mutation_snapshot(value, "sidebar_view")
    }
}

#[derive(Clone, Debug)]
pub struct ConnectedClient {
    session: Session,
    selector: Selector<ConnectedClientId>,
}

impl ConnectedClient {
    pub fn selector(&self) -> &Selector<ConnectedClientId> {
        &self.selector
    }

    fn params(&self) -> Params {
        self.session.params().selector(field::CLIENT, &self.selector)
    }

    pub fn refresh(&self) -> Result<ConnectedClientSnapshot> {
        wire::snapshot(&self.session.client.read(ops::CLIENT_GET, self.params())?, "client")
    }

    pub fn update_metadata(&self, options: ClientMetadataOptions) -> Result<ClientSnapshot> {
        wire::decode_exact(
            &self.session.client.connection_control(
                ops::CLIENT_METADATA_UPDATE,
                self.params().extend(metadata_params(options)?),
            )?,
            "client metadata update result",
        )
    }

    pub fn set_sizing(
        &self,
        terminal: &Terminal,
        options: ClientSizingOptions,
    ) -> Result<ClientSnapshot> {
        wire::decode_exact(
            &self.session.client.connection_control(
                ops::CLIENT_SIZING_SET,
                self.params()
                    .extend(terminal.path.params())
                    .selector(field::TERMINAL, &terminal.selector)
                    .boolean(field::ENABLED, options.enabled)
                    .optional_bool(field::EXCLUSIVE, options.exclusive),
            )?,
            "client sizing result",
        )
    }

    pub fn release_sizing(&self, terminal: &Terminal) -> Result<ClientSnapshot> {
        wire::decode_exact(
            &self.session.client.connection_control(
                ops::CLIENT_SIZING_RELEASE,
                self.params()
                    .extend(terminal.path.params())
                    .selector(field::TERMINAL, &terminal.selector),
            )?,
            "client sizing release result",
        )
    }

    pub fn set_cell_pixels(&self, options: CellPixelsOptions) -> Result<CellPixelsResult> {
        wire::validate_pixel_size(PixelSize {
            width_px: options.width_px,
            height_px: options.height_px,
        })?;
        wire::decode_exact(
            &self.session.client.connection_control(
                ops::CLIENT_CELL_PIXELS_SET,
                self.params()
                    .u32(field::WIDTH_PX, options.width_px)
                    .u32(field::HEIGHT_PX, options.height_px),
            )?,
            "cell pixels result",
        )
    }

    pub fn detach(&self) -> Result<()> {
        decode_empty(&self.session.client.connection_control(ops::CLIENT_DETACH, self.params())?)
    }
}

#[derive(Clone, Debug)]
pub struct PairingRequest {
    session: Session,
    selector: Selector<PairingRequestId>,
}

impl PairingRequest {
    fn params(&self) -> Params {
        self.session.params().selector(field::PAIRING_REQUEST, &self.selector)
    }

    pub fn refresh(&self) -> Result<PairingRequestSnapshot> {
        let snapshots = wire::list::<PairingRequestSnapshot>(
            &self.session.client.read(ops::PAIRING_REQUEST_LIST, self.session.params())?,
            "pairing_requests",
            "pairing_request",
        )?;
        let id = match &self.selector {
            Selector::Id(id) => id,
            Selector::Current(_) | Selector::Name(_) => {
                return Err(Error::InvalidArgument(
                    "pairing request refresh requires an ID handle".to_string(),
                ));
            }
        };
        snapshots.into_iter().find(|snapshot| &snapshot.id == id).ok_or_else(|| Error::Protocol {
            code: "selector.not_found".to_string(),
            message: format!("pairing request {id} no longer exists"),
            details: serde_json::json!({"id": id}),
            retryable: false,
        })
    }

    pub fn resolve(
        &self,
        options: PairingResolveOptions,
    ) -> Result<MutationResult<PairingResolutionResult>> {
        self.resolve_with(options, MutationOptions::unique()?)
    }

    pub fn resolve_with(
        &self,
        options: PairingResolveOptions,
        mutation: MutationOptions,
    ) -> Result<MutationResult<PairingResolutionResult>> {
        mutation_result(
            self.session.client.mutate(
                ops::PAIRING_REQUEST_RESOLVE,
                self.params().string(
                    field::DECISION,
                    match options.decision {
                        PairingDecision::Accept => "accept",
                        PairingDecision::Reject => "reject",
                    },
                ),
                mutation,
            )?,
            |value| wire::decode_exact(value, "pairing resolution result"),
        )
    }
}

#[derive(Clone, Debug)]
pub struct FrontendProjection {
    session: Session,
    selector: Selector<FrontendProjectionId>,
}

impl FrontendProjection {
    fn params(&self) -> Params {
        self.session.params().selector(field::FRONTEND_PROJECTION, &self.selector)
    }

    pub fn refresh(&self) -> Result<FrontendProjectionSnapshot> {
        wire::snapshot(
            &self.session.client.read(ops::FRONTEND_PROJECTION_GET, self.params())?,
            "frontend_projection",
        )
    }

    pub fn put(
        &self,
        options: ProjectionOptions,
    ) -> Result<MutationResult<FrontendProjectionSnapshot>> {
        self.put_with(options, MutationOptions::unique()?)
    }

    pub fn put_with(
        &self,
        options: ProjectionOptions,
        mutation: MutationOptions,
    ) -> Result<MutationResult<FrontendProjectionSnapshot>> {
        mutation_snapshot(
            self.session.client.mutate(
                ops::FRONTEND_PROJECTION_PUT,
                self.params()
                    .string(field::FRONTEND_ID, options.frontend_id)
                    .string(field::WINDOW_ID, options.window_id)
                    .string(field::GENERATION, options.generation)
                    .value(field::PROJECTION, options.projection)
                    .optional_u64(
                        field::EXPECTED_PROJECTION_REVISION,
                        options.expected_projection_revision,
                    ),
                mutation,
            )?,
            "frontend_projection",
        )
    }
}

#[derive(Clone, Debug)]
pub struct Notification {
    session: Session,
    selector: Selector<NotificationId>,
}

impl Notification {
    pub fn selector(&self) -> &Selector<NotificationId> {
        &self.selector
    }

    pub fn refresh(&self) -> Result<NotificationSnapshot> {
        let id = id_selector(&self.selector, "notification")?;
        wire::list::<NotificationSnapshot>(
            &self.session.client.read(ops::NOTIFICATION_LIST, self.session.params())?,
            "notifications",
            "notification",
        )?
        .into_iter()
        .find(|snapshot| &snapshot.id == id)
        .ok_or_else(|| not_found("notification", id))
    }
}

#[derive(Clone, Debug)]
pub struct Agent {
    session: Session,
    selector: Selector<AgentId>,
}

impl Agent {
    pub fn selector(&self) -> &Selector<AgentId> {
        &self.selector
    }

    pub fn refresh(&self) -> Result<AgentSnapshot> {
        let id = id_selector(&self.selector, "agent")?;
        wire::list::<AgentSnapshot>(
            &self.session.client.read(ops::AGENT_LIST, self.session.params())?,
            "agents",
            "agent",
        )?
        .into_iter()
        .find(|snapshot| &snapshot.id == id)
        .ok_or_else(|| not_found("agent", id))
    }
}

#[derive(Clone, Debug)]
pub struct SidebarView {
    session: Session,
    selector: Selector<SidebarViewId>,
}

impl SidebarView {
    pub fn selector(&self) -> &Selector<SidebarViewId> {
        &self.selector
    }

    fn params(&self) -> Params {
        self.session.params().selector(field::SIDEBAR_VIEW, &self.selector)
    }

    pub fn refresh(&self) -> Result<SidebarViewSnapshot> {
        wire::snapshot(
            &self.session.client.read(ops::SIDEBAR_VIEW_GET, self.params())?,
            "sidebar_view",
        )
    }

    pub fn attach(&self) -> Result<SidebarViewStream> {
        self.session
            .client
            .stream(ops::SIDEBAR_VIEW_ATTACH, self.params())
            .map(SidebarViewStream::new)
    }

    pub fn input(&self, options: SidebarInputOptions) -> Result<MutationReceipt> {
        self.input_with(options, MutationOptions::unique()?)
    }

    pub fn input_with(
        &self,
        options: SidebarInputOptions,
        mutation: MutationOptions,
    ) -> Result<MutationReceipt> {
        mutation_empty(self.session.client.mutate(
            ops::SIDEBAR_VIEW_INPUT,
            self.params().extend(wire::sidebar_input(options)),
            mutation,
        )?)
    }

    pub fn resize(&self, options: Size) -> Result<MutationResult<SidebarViewSnapshot>> {
        self.resize_with(options, MutationOptions::unique()?)
    }

    pub fn resize_with(
        &self,
        options: Size,
        mutation: MutationOptions,
    ) -> Result<MutationResult<SidebarViewSnapshot>> {
        wire::validate_size(options)?;
        mutation_snapshot(
            self.session.client.mutate(
                ops::SIDEBAR_VIEW_RESIZE,
                self.params().u16(field::COLS, options.cols).u16(field::ROWS, options.rows),
                mutation,
            )?,
            "sidebar_view",
        )
    }

    pub fn reload(&self) -> Result<MutationResult<SidebarViewSnapshot>> {
        self.reload_with(MutationOptions::unique()?)
    }

    pub fn reload_with(
        &self,
        mutation: MutationOptions,
    ) -> Result<MutationResult<SidebarViewSnapshot>> {
        mutation_snapshot(
            self.session.client.mutate(ops::SIDEBAR_VIEW_RELOAD, self.params(), mutation)?,
            "sidebar_view",
        )
    }
}

fn id_selector<'a, I: OpaqueId>(selector: &'a Selector<I>, kind: &str) -> Result<&'a I> {
    match selector {
        Selector::Id(id) => Ok(id),
        Selector::Current(_) | Selector::Name(_) => {
            Err(Error::InvalidArgument(format!("{kind} refresh requires an ID handle")))
        }
    }
}

fn not_found<I: OpaqueId>(kind: &str, id: &I) -> Error {
    Error::Protocol {
        code: "selector.not_found".to_string(),
        message: format!("{kind} {id} no longer exists"),
        details: serde_json::json!({"id": id.as_str()}),
        retryable: false,
    }
}
