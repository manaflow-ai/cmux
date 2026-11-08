use crate::{Error, Result};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use std::fmt;
use std::hash::Hash;
use std::marker::PhantomData;
use std::str::FromStr;

/// Trait implemented by every validated opaque cmux resource ID.
pub trait OpaqueId:
    Clone + fmt::Debug + fmt::Display + Eq + Ord + Hash + Serialize + DeserializeOwned + Send + Sync
{
    const PREFIX: &'static str;

    fn parse(value: impl Into<String>) -> Result<Self>;
    fn as_str(&self) -> &str;
    fn into_string(self) -> String;
}

macro_rules! opaque_id {
    ($name:ident, $prefix:literal) => {
        #[derive(Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
        pub struct $name(String);

        impl $name {
            pub const PREFIX: &'static str = $prefix;

            pub fn parse(value: impl Into<String>) -> Result<Self> {
                <Self as OpaqueId>::parse(value)
            }

            pub fn as_str(&self) -> &str {
                &self.0
            }

            pub fn into_string(self) -> String {
                self.0
            }
        }

        impl OpaqueId for $name {
            const PREFIX: &'static str = $prefix;

            fn parse(value: impl Into<String>) -> Result<Self> {
                let value = value.into();
                let Some(payload) = value.strip_prefix(concat!($prefix, "_")) else {
                    return Err(Error::InvalidId { expected_prefix: $prefix, value });
                };
                if payload.len() != 32
                    || !payload
                        .bytes()
                        .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
                {
                    return Err(Error::InvalidId { expected_prefix: $prefix, value });
                }
                Ok(Self(value))
            }

            fn as_str(&self) -> &str {
                &self.0
            }

            fn into_string(self) -> String {
                self.0
            }
        }

        impl fmt::Debug for $name {
            fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.debug_tuple(stringify!($name)).field(&self.0).finish()
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str(&self.0)
            }
        }

        impl FromStr for $name {
            type Err = Error;

            fn from_str(value: &str) -> Result<Self> {
                Self::parse(value)
            }
        }

        impl Serialize for $name {
            fn serialize<S>(&self, serializer: S) -> std::result::Result<S::Ok, S::Error>
            where
                S: Serializer,
            {
                serializer.serialize_str(&self.0)
            }
        }

        impl<'de> Deserialize<'de> for $name {
            fn deserialize<D>(deserializer: D) -> std::result::Result<Self, D::Error>
            where
                D: Deserializer<'de>,
            {
                Self::parse(String::deserialize(deserializer)?).map_err(serde::de::Error::custom)
            }
        }
    };
}

opaque_id!(MachineId, "machine");
opaque_id!(SessionId, "session");
opaque_id!(WorkspaceId, "ws");
opaque_id!(ScreenId, "screen");
opaque_id!(PaneId, "pane");
opaque_id!(TabId, "tab");
opaque_id!(TerminalId, "term");
opaque_id!(BrowserId, "browser");
opaque_id!(ConnectedClientId, "client");
opaque_id!(SplitId, "split");
opaque_id!(NotificationId, "notification");
opaque_id!(AgentId, "agent");
opaque_id!(FrontendProjectionId, "projection");
opaque_id!(PairingRequestId, "pairing");
opaque_id!(SidebarViewId, "sidebar_view");
opaque_id!(StreamId, "stream");

/// An explicit ID, current-resource, or exact-name selector.
///
/// Names are never assumed to be unique. Methods named `find_by_name` return
/// all exact matches; operations using a name selector preserve server-side
/// ambiguity errors and their candidate IDs.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Selector<I> {
    Id(I),
    Current(PhantomData<fn() -> I>),
    Name(String),
}

impl<I> Selector<I> {
    pub fn id(id: I) -> Self {
        Self::Id(id)
    }

    pub const fn current() -> Self {
        Self::Current(PhantomData)
    }

    pub fn name(name: impl Into<String>) -> Self {
        Self::Name(name.into())
    }

    pub fn exact_name(&self) -> Option<&str> {
        match self {
            Self::Name(name) => Some(name),
            Self::Id(_) | Self::Current(_) => None,
        }
    }
}

impl<I> From<I> for Selector<I> {
    fn from(id: I) -> Self {
        Self::Id(id)
    }
}

impl<I> Serialize for Selector<I>
where
    I: Serialize,
{
    fn serialize<S>(&self, serializer: S) -> std::result::Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        use serde::ser::SerializeMap;

        let mut map = serializer.serialize_map(None)?;
        match self {
            Self::Id(id) => {
                map.serialize_entry("kind", "id")?;
                map.serialize_entry("id", id)?;
            }
            Self::Current(_) => {
                map.serialize_entry("kind", "current")?;
            }
            Self::Name(name) => {
                map.serialize_entry("kind", "name")?;
                map.serialize_entry("name", name)?;
            }
        }
        map.end()
    }
}

impl<'de, I> Deserialize<'de> for Selector<I>
where
    I: Deserialize<'de>,
{
    fn deserialize<D>(deserializer: D) -> std::result::Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        #[derive(Deserialize)]
        #[serde(tag = "kind", rename_all = "snake_case")]
        enum WireSelector<I> {
            Id { id: I },
            Current,
            Name { name: String },
        }

        Ok(match WireSelector::deserialize(deserializer)? {
            WireSelector::Id { id } => Self::Id(id),
            WireSelector::Current => Self::current(),
            WireSelector::Name { name } => Self::Name(name),
        })
    }
}
