//! `acpmux machine hypervisor serve | apply | ls`: the host agent (`crate::hypervisor`).
//! No daemon: the host agent is its own process (a systemd unit on the host).

use crate::cli::command_host::{HypervisorCmd, HypervisorOpts};
use crate::cli::output::print_json;
use crate::hypervisor::HypervisorDriver;
use crate::hypervisor::libvirt::{LibvirtConfig, LibvirtDriver, ProcessRunner};
use crate::hypervisor::serve::{HostAgent, action_line};
use crate::hypervisor::source::{Command, SpoolSource};
use anyhow::{Context, Result};
use std::io::Read;
use std::path::PathBuf;

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn state_dir(opts: &HypervisorOpts) -> PathBuf {
    opts.state_dir.clone().unwrap_or_else(|| crate::config::home().join("hypervisor"))
}

fn libvirt(opts: &HypervisorOpts) -> LibvirtConfig {
    let mut config = LibvirtConfig::new(state_dir(opts).join("images"));
    config.connect = opts.connect.clone();
    config
}

pub async fn run(cmd: HypervisorCmd, json_out: bool) -> Result<()> {
    tokio::task::spawn_blocking(move || run_blocking(cmd, json_out)).await?
}

fn run_blocking(cmd: HypervisorCmd, json_out: bool) -> Result<()> {
    match cmd {
        HypervisorCmd::Serve { opts, base_image, network, template, interval_secs, once } => {
            let dir = state_dir(&opts);
            let mut config = libvirt(&opts);
            config.base_image = base_image;
            config.network = network;
            if let Some(path) = template {
                config.template = std::fs::read_to_string(&path)
                    .with_context(|| format!("read template {}", path.display()))?;
            }
            let driver = LibvirtDriver::new(config, ProcessRunner);
            let source = SpoolSource::new(dir.join("spool"));
            let mut agent = HostAgent::open(driver, source, dir)?;
            loop {
                match agent.tick(now_ms()) {
                    Ok(tick) => {
                        if json_out {
                            print_json(&serde_json::to_value(&tick)?);
                        } else {
                            for a in &tick.applied {
                                match &a.outcome.error {
                                    None => println!("{}: done", a.id),
                                    Some(e) => println!("{}: failed: {e}", a.id),
                                }
                            }
                            tick.enforced.iter().for_each(|e| println!("{}", action_line(e)));
                        }
                    }
                    Err(e) if !once => eprintln!("hypervisor pass failed: {e:#}"),
                    Err(e) => return Err(e),
                }
                if once {
                    return Ok(());
                }
                std::thread::sleep(std::time::Duration::from_secs(interval_secs.max(1)));
            }
        }
        HypervisorCmd::Apply { opts, id } => {
            let mut text = String::new();
            std::io::stdin().read_to_string(&mut text)?;
            let command: Command =
                serde_json::from_str(&text).context("parse the command on stdin")?;
            let env =
                SpoolSource::new(state_dir(&opts).join("spool")).submit(command, id, now_ms())?;
            if json_out {
                print_json(&serde_json::to_value(&env)?);
            } else {
                println!("queued {}", env.id);
            }
            Ok(())
        }
        HypervisorCmd::Ls { opts } => {
            let dir = state_dir(&opts);
            let driver = LibvirtDriver::new(libvirt(&opts), ProcessRunner);
            let book = crate::hypervisor::lease::LeaseBook::load(&dir.join("leases.json"))?;
            let slots = driver.list()?;
            let rows: Vec<serde_json::Value> = slots
                .iter()
                .map(|s| {
                    serde_json::json!({
                        "slot": s.name,
                        "state": s.state,
                        "lease": book.slots.get(&s.name),
                    })
                })
                .collect();
            if json_out {
                print_json(&serde_json::Value::Array(rows));
            } else if slots.is_empty() {
                println!("no cmux VMs on this host");
            } else {
                for s in &slots {
                    let lease =
                        if book.slots.contains_key(&s.name) { "" } else { "  (no lease: orphan)" };
                    println!("{}  {:?}{lease}", s.name, s.state);
                }
            }
            Ok(())
        }
    }
}
