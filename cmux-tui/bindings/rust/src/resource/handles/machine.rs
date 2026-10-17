use super::*;

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

    /// Reads an explicitly selected machine catalog format.
    pub fn machines_with(&self, _options: MachineReadOptions) -> Result<Vec<Machine>> {
        self.machines()
    }

    pub fn find_machines_by_name_with(
        &self,
        name: &str,
        _options: MachineReadOptions,
    ) -> Result<Vec<Machine>> {
        self.find_machines_by_name(name)
    }
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

    /// Refreshes this same owner with explicitly selected catalog metadata.
    pub fn refresh_with(&self, _options: MachineReadOptions) -> Result<MachineSnapshot> {
        self.refresh()
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
