# Add project specific ProGuard rules here.
-keepattributes *Annotation*
-keepclassmembers class * {
    @com.google.gson.annotations.SerializedName <fields>;
}
# Kotlinx Serialization
-keepattributes InnerClasses
-keep class kotlinx.serialization.** { *; }
