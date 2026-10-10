use serde::{Deserialize, Deserializer, Serialize, Serializer};

/// An optional nullable JSON field.
///
/// `Missing` omits the field, `Null` emits an explicit JSON `null`, and
/// `Value(T)` emits the value. Generated models use this type only when the
/// schema permits all three states.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Optional<T> {
    #[default]
    Missing,
    Null,
    Value(T),
}

impl<T> Optional<T> {
    pub const fn is_missing(&self) -> bool {
        matches!(self, Self::Missing)
    }

    pub const fn is_null(&self) -> bool {
        matches!(self, Self::Null)
    }

    pub const fn as_ref(&self) -> Optional<&T> {
        match self {
            Self::Missing => Optional::Missing,
            Self::Null => Optional::Null,
            Self::Value(value) => Optional::Value(value),
        }
    }

    pub fn map<U>(self, map: impl FnOnce(T) -> U) -> Optional<U> {
        match self {
            Self::Missing => Optional::Missing,
            Self::Null => Optional::Null,
            Self::Value(value) => Optional::Value(map(value)),
        }
    }
}

impl<T> From<T> for Optional<T> {
    fn from(value: T) -> Self {
        Self::Value(value)
    }
}

impl<T> Serialize for Optional<T>
where
    T: Serialize,
{
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        match self {
            // Generated fields always pair this state with
            // `skip_serializing_if`. Serializing it directly as null is the
            // least surprising fallback for callers using Optional standalone.
            Self::Missing | Self::Null => serializer.serialize_none(),
            Self::Value(value) => value.serialize(serializer),
        }
    }
}

impl<'de, T> Deserialize<'de> for Optional<T>
where
    T: Deserialize<'de>,
{
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        Option::<T>::deserialize(deserializer).map(|value| match value {
            Some(value) => Self::Value(value),
            None => Self::Null,
        })
    }
}

/// Deserializes a present optional field while rejecting an explicit JSON null.
///
/// Serde supplies `Option::default()` when the field is omitted, so this
/// function only handles present values.
pub(crate) fn deserialize_optional_non_null<'de, D, T>(
    deserializer: D,
) -> Result<Option<T>, D::Error>
where
    D: Deserializer<'de>,
    T: Deserialize<'de>,
{
    match Option::<T>::deserialize(deserializer)? {
        Some(value) => Ok(Some(value)),
        None => Err(serde::de::Error::custom("explicit null is not allowed for this field")),
    }
}

/// Backwards-compatible name for a required nullable value.
pub type Nullable<T> = crate::raw_support::RequiredNullable<T>;
