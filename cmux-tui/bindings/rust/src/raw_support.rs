use serde::de::Visitor;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use std::fmt;
use std::marker::PhantomData;
use std::result::Result as StdResult;

/// Static compatibility and authorization information for a legacy command.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CommandMetadata {
    pub name: &'static str,
    pub since: u32,
    pub capability: Option<&'static str>,
    pub authority: &'static str,
    pub stream: Option<StreamMetadata>,
}

/// Static lifecycle information for a legacy streaming command.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StreamMetadata {
    pub kind: &'static str,
    pub terminal_event: Option<&'static str>,
}

/// Static compatibility and routing information for a legacy event.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EventMetadata {
    pub name: &'static str,
    pub since: u32,
    pub capability: Option<&'static str>,
    pub streams: &'static [&'static str],
    pub emission: &'static str,
}

/// Static description of a legacy protocol profile.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProfileMetadata {
    pub name: &'static str,
    pub description: &'static str,
    pub inherits: &'static [&'static str],
    pub transport: Option<&'static str>,
    pub requires_authority: bool,
}

/// A required JSON field whose value may explicitly be `null`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RequiredNullable<T>(pub Option<T>);

impl<T> RequiredNullable<T> {
    pub const fn null() -> Self {
        Self(None)
    }

    pub const fn value(value: T) -> Self {
        Self(Some(value))
    }

    pub const fn is_null(&self) -> bool {
        self.0.is_none()
    }

    pub fn as_ref(&self) -> RequiredNullable<&T> {
        RequiredNullable(self.0.as_ref())
    }

    pub fn into_option(self) -> Option<T> {
        self.0
    }
}

impl<T> RequiredNullable<T>
where
    T: std::ops::Deref,
{
    pub fn as_deref(&self) -> RequiredNullable<&T::Target> {
        RequiredNullable(self.0.as_deref())
    }
}

impl<T> From<Option<T>> for RequiredNullable<T> {
    fn from(value: Option<T>) -> Self {
        Self(value)
    }
}

impl<T> Serialize for RequiredNullable<T>
where
    T: Serialize,
{
    fn serialize<S>(&self, serializer: S) -> StdResult<S::Ok, S::Error>
    where
        S: Serializer,
    {
        self.0.serialize(serializer)
    }
}

impl<'de, T> Deserialize<'de> for RequiredNullable<T>
where
    T: Deserialize<'de>,
{
    fn deserialize<D>(deserializer: D) -> StdResult<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        struct RequiredNullableVisitor<T>(PhantomData<T>);

        impl<'de, T> Visitor<'de> for RequiredNullableVisitor<T>
        where
            T: Deserialize<'de>,
        {
            type Value = RequiredNullable<T>;

            fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str("an explicit null or value")
            }

            fn visit_newtype_struct<D>(self, deserializer: D) -> StdResult<Self::Value, D::Error>
            where
                D: Deserializer<'de>,
            {
                Option::<T>::deserialize(deserializer).map(RequiredNullable)
            }
        }

        deserializer
            .deserialize_newtype_struct("RequiredNullable", RequiredNullableVisitor(PhantomData))
    }
}
