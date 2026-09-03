plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.hilt)
    alias(libs.plugins.ksp)
}

android {
    namespace = "dev.cmux.android"
    compileSdk = 36

    defaultConfig {
        applicationId = "dev.cmux.android"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0-demo"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        manifestPlaceholders["appAuthRedirectScheme"] = "dev.cmux.android"
    }

    buildTypes {
        debug {
            isDebuggable = true
            buildConfigField("String", "CMUX_EMULATOR_HOST", "\"10.0.2.2\"")
            buildConfigField("int", "CMUX_DEFAULT_PORT", "58465")
        }
        release {
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            buildConfigField("String", "CMUX_EMULATOR_HOST", "\"10.0.2.2\"")
            buildConfigField("int", "CMUX_DEFAULT_PORT", "58465")
        }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    implementation(platform(libs.compose.bom))
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.compose.ui)
    implementation(libs.compose.ui.graphics)
    implementation(libs.compose.ui.tooling.preview)
    implementation(libs.compose.material3)
    implementation(libs.compose.foundation)
    implementation(libs.navigation.compose)
    implementation(libs.hilt.navigation.compose)
    implementation(libs.lifecycle.viewmodel.compose)
    implementation(libs.lifecycle.runtime.compose)
    implementation(libs.hilt.android)
    ksp(libs.hilt.compiler)
    implementation(libs.coroutines.android)

    implementation(project(":core:transport"))
    implementation(project(":core:rpc"))
    implementation(project(":core:auth"))
    implementation(project(":core:pairing"))
    implementation(project(":feature:auth"))
    implementation(project(":feature:pairing"))
    implementation(project(":feature:workspace"))
    implementation(project(":feature:terminal"))
    implementation(project(":feature:browser"))

    debugImplementation(libs.compose.ui.tooling)
}
