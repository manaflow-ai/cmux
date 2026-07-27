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

/// Backwards-compatible name for a required nullable value.
pub type Nullable<T> = crate::RequiredNullable<T>;

#[cfg(test)]
mod tests {
    use super::*;
    use serde::{Deserialize, Serialize};

    #[derive(Debug, Deserialize, Serialize)]
    struct Wire {
        #[serde(default, skip_serializing_if = "Optional::is_missing")]
        value: Optional<String>,
    }

    #[test]
    fn optional_preserves_missing_null_and_value() {
        let missing: Wire = serde_json::from_str("{}").unwrap();
        let null: Wire = serde_json::from_str(r#"{"value":null}"#).unwrap();
        let value: Wire = serde_json::from_str(r#"{"value":"x"}"#).unwrap();

        assert_eq!(missing.value, Optional::Missing);
        assert_eq!(null.value, Optional::Null);
        assert_eq!(value.value, Optional::Value("x".to_string()));
        assert_eq!(serde_json::to_string(&missing).unwrap(), "{}");
        assert_eq!(serde_json::to_string(&null).unwrap(), r#"{"value":null}"#);
        assert_eq!(serde_json::to_string(&value).unwrap(), r#"{"value":"x"}"#);
    }

    #[derive(Debug, Deserialize)]
    struct Required {
        value: Nullable<String>,
    }

    #[test]
    fn required_nullable_rejects_missing() {
        assert!(serde_json::from_str::<Required>("{}").is_err());
        let null: Required = serde_json::from_str(r#"{"value":null}"#).unwrap();
        assert_eq!(null.value, Nullable::null());
        let value: Required = serde_json::from_str(r#"{"value":"x"}"#).unwrap();
        assert_eq!(value.value, Nullable::value("x".to_string()));
    }
}
