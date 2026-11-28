use super::*;
use crate::Transport;

fn request() -> ConnectRequest {
    ConnectRequest {
        base_url: "https://api.example.test".into(),
        token: "user:alice".into(),
        team_id: "team".into(),
        device_id: "phone".into(),
        mac_device_id: "mac".into(),
        transport: Transport::WireGuard,
        include_loopback: false,
        relay_only: false,
        force_relay: false,
        block_udp: false,
        proxy_only: false,
        drop_wireguard: false,
        video_lane: false,
        webrtc_media: false,
        ultra: cmux_mobile_link::UltraSetting::Off,
    }
}

fn no_env(_: &str) -> bool {
    false
}

#[test]
fn a_plain_dial_races_the_direct_paths() {
    let plain = Simulation::with_env(&request(), no_env);
    assert_eq!(plain, Simulation::default());
    assert!(!plain.direct_paths_off());
}

#[test]
fn each_rig_variable_alone_turns_the_direct_paths_off() {
    // review.sh's relay-only relaunch sets only CMUX_MOBILE_DEV_RELAY_ONLY=1, never the request's field:
    // the regression was a LAN link under it on a phone with Local Network access.
    for name in [
        "CMUX_MOBILE_DEV_RELAY_ONLY",
        "CMUX_MOBILE_DEV_BLOCK_UDP",
        "CMUX_MOBILE_DEV_PROXY_ONLY",
        "CMUX_MOBILE_DEV_DROP_WIREGUARD",
        "CMUX_MOBILE_DEV_FORCE_RELAY",
    ] {
        let simulated = Simulation::with_env(&request(), |set| set == name);
        assert!(simulated.direct_paths_off(), "{name} alone");
        assert_ne!(simulated, Simulation::default(), "{name} reaches the relayed dial's options too");
    }
}

#[test]
fn each_app_option_alone_turns_the_direct_paths_off() {
    let options: [fn(&mut ConnectRequest); 5] = [
        |r| r.relay_only = true,
        |r| r.block_udp = true,
        |r| r.proxy_only = true,
        |r| r.drop_wireguard = true,
        |r| r.force_relay = true,
    ];
    for (index, set) in options.iter().enumerate() {
        let mut asked = request();
        set(&mut asked);
        assert!(Simulation::with_env(&asked, no_env).direct_paths_off(), "option {index}");
    }
}

#[test]
fn a_proxy_only_network_blocks_udp_too() {
    let from_env = Simulation::with_env(&request(), |name| name == "CMUX_MOBILE_DEV_PROXY_ONLY");
    assert!(from_env.proxy_only && from_env.block_udp);
    let mut asked = request();
    asked.proxy_only = true;
    let from_app = Simulation::with_env(&asked, no_env);
    assert!(from_app.proxy_only && from_app.block_udp);
}

#[test]
fn another_variable_turns_nothing_on() {
    let other = Simulation::with_env(&request(), |name| name == "CMUX_MOBILE_DEV_PROXY");
    assert!(!other.direct_paths_off(), "the proxy's address alone is not a proxy-only network");
}
